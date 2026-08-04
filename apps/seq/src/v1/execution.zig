const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const plan = @import("plan.zig");
const physical = @import("physical.zig");

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    json: []const u8,
    null,
};

pub const Rows = struct {
    values: []const Value,
    width: usize,

    pub fn count(self: Rows) !usize {
        if (self.width == 0 or self.values.len % self.width != 0) {
            return error.InvalidObservationRows;
        }
        return self.values.len / self.width;
    }

    pub fn row(self: Rows, index: usize) []const Value {
        return self.values[index * self.width ..][0..self.width];
    }
};

pub const Result = struct {
    values: []Value,
    width: usize,
    row_count: usize,
    source_row_count: usize,
    materialized_row_count: usize,

    pub fn rows(self: Result) Rows {
        return .{
            .values = self.values[0 .. self.row_count * self.width],
            .width = self.width,
        };
    }
};

pub const Source = union(enum) {
    physical: physical.Relation,
    external: u16,
};

pub const RuntimePredicate = struct {
    field_index: u16,
    operator: plan.PredicateOperator,
    operand: Value,
    case_insensitive: bool,
};

pub const PredicateRange = struct {
    start: u16,
    len: u16,
};

pub const RuntimeSortKey = struct {
    field_index: u16,
    direction: plan.SortDirection,
    nulls: plan.NullOrder,
};

pub const FieldRange = struct {
    start: u16,
    len: u16,
};

pub const RuntimeAggregateMetric = struct {
    function: plan.AggregateFunction,
    field_index: ?u16,
    output_kind: plan.ColumnKind,
};

pub const RuntimeTopK = struct {
    keys: FieldRange,
    count: usize,
};

pub const RuntimeOperation = union(enum) {
    filter_all: PredicateRange,
    filter_any: PredicateRange,
    limit: struct {
        count: usize,
        state_index: u16,
    },
    sort: FieldRange,
    top_k: RuntimeTopK,
    distinct: FieldRange,
    aggregate: FieldRange,
};

pub const Program = struct {
    source: Source,
    source_width: u16,
    source_field_indices: []u16,
    materialized_field_indices: []u16,
    source_row_bound: ?usize,
    operations: []RuntimeOperation,
    predicates: []RuntimePredicate,
    sort_keys: []RuntimeSortKey,
    distinct_fields: []u16,
    aggregate_metrics: []RuntimeAggregateMetric,
    output_field_indices: []u16,
    limit_state_count: u16,
    first_blocking_operation: ?u16,
    max_rows: usize,

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        allocator.free(self.source_field_indices);
        allocator.free(self.materialized_field_indices);
        allocator.free(self.operations);
        allocator.free(self.predicates);
        allocator.free(self.sort_keys);
        allocator.free(self.distinct_fields);
        allocator.free(self.aggregate_metrics);
        allocator.free(self.output_field_indices);
        self.* = undefined;
    }
};

pub fn excludedSessionId(program: *const Program) ?[]const u8 {
    const relation = switch (program.source) {
        .physical => |value| value,
        .external => return null,
    };
    const physical_index = relation.fieldIndex("session_id") catch return null;
    var row_index: ?u16 = null;
    for (program.source_field_indices, 0..) |field_index, index| {
        if (field_index == physical_index) {
            row_index = @intCast(index);
            break;
        }
    }
    const wanted_index = row_index orelse return null;
    for (program.operations) |operation| {
        const range = switch (operation) {
            .filter_all => |value| value,
            else => break,
        };
        const end = @as(usize, range.start) + range.len;
        for (program.predicates[range.start..end]) |predicate| {
            if (predicate.field_index != wanted_index or
                predicate.operator != .not_equal)
            {
                continue;
            }
            const excluded = switch (predicate.operand) {
                .string => |value| value,
                else => continue,
            };
            if (excluded.len != 0) return excluded;
        }
    }
    return null;
}

test "session exclusion derives from conjunctive not-equal predicate" {
    var source_fields = [_]u16{1};
    var operations = [_]RuntimeOperation{
        .{ .filter_all = .{ .start = 0, .len = 1 } },
    };
    var predicates = [_]RuntimePredicate{.{
        .field_index = 0,
        .operator = .not_equal,
        .operand = .{ .string = "session-current" },
        .case_insensitive = false,
    }};
    var program = Program{
        .source = .{ .physical = .source_events },
        .source_width = 1,
        .source_field_indices = &source_fields,
        .materialized_field_indices = &.{},
        .source_row_bound = null,
        .operations = &operations,
        .predicates = &predicates,
        .sort_keys = &.{},
        .distinct_fields = &.{},
        .aggregate_metrics = &.{},
        .output_field_indices = &.{},
        .limit_state_count = 0,
        .first_blocking_operation = null,
        .max_rows = 1,
    };
    try std.testing.expectEqualStrings(
        "session-current",
        excludedSessionId(&program).?,
    );
    program.operations[0] = .{ .filter_any = .{ .start = 0, .len = 1 } };
    try std.testing.expect(excludedSessionId(&program) == null);
    var later_operations = [_]RuntimeOperation{
        .{ .limit = .{ .count = 1, .state_index = 0 } },
        .{ .filter_all = .{ .start = 0, .len = 1 } },
    };
    program.operations = &later_operations;
    try std.testing.expect(excludedSessionId(&program) == null);
}

pub fn compile(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    bindings: *const definition_core.parameters.Bindings,
    projection_name: []const u8,
) !Program {
    const projection_index = findProjection(
        definition_plan.projections,
        projection_name,
    ) orelse return error.UnknownObservationProjection;
    const projection = native_plan.projections[projection_index];
    const resolved = try resolveSource(
        definition_plan,
        native_plan,
        projection.stage_index,
    );
    var builder = try ProgramBuilder.init(
        allocator,
        definition_plan,
        native_plan,
        bindings,
        resolved.source_width,
    );
    defer builder.deinit();
    var path_index = resolved.stage_count;
    while (path_index > 0) {
        path_index -= 1;
        const stage = &native_plan.stages[
            resolved.stage_path[path_index]
        ];
        try builder.applyStage(stage);
    }
    return builder.finish(&resolved, &projection);
}

const ResolvedSource = struct {
    source: Source,
    source_width: usize,
    physical_field_indices: ?[]const u16,
    source_row_bound: ?usize,
    stage_path: [256]u16,
    stage_count: usize,
};

fn resolveSource(
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    projection_stage_index: u16,
) !ResolvedSource {
    var resolved: ResolvedSource = undefined;
    resolved.stage_count = 0;
    var current_index = projection_stage_index;
    while (resolved.stage_count < resolved.stage_path.len) {
        resolved.stage_path[resolved.stage_count] = current_index;
        resolved.stage_count += 1;
        const stage = &native_plan.stages[current_index];
        if (stage.source) |stage_source| {
            switch (stage_source) {
                .stage => |index| {
                    current_index = index;
                    continue;
                },
                .external => |index| {
                    resolved.source = .{ .external = index };
                    resolved.source_width =
                        definition_plan.inputs[index].fields.len;
                    resolved.source_row_bound =
                        definition_plan.inputs[index].max_rows;
                    resolved.physical_field_indices = null;
                    return resolved;
                },
            }
        }
        const scan = switch (stage.operation) {
            .scan => |value| value,
            else => return error.ObservationPipelineSourceMissing,
        };
        resolved.source = .{ .physical = scan.relation };
        resolved.source_width = scan.field_indices.len;
        resolved.physical_field_indices = scan.field_indices;
        resolved.source_row_bound = null;
        return resolved;
    }
    return error.ObservationPipelineTooDeep;
}

const ProgramBuilder = struct {
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    bindings: *const definition_core.parameters.Bindings,
    field_map: [256]u16,
    field_count: usize,
    predicates: std.ArrayList(RuntimePredicate) = .empty,
    operations: std.ArrayList(RuntimeOperation) = .empty,
    sort_keys: std.ArrayList(RuntimeSortKey) = .empty,
    distinct_fields: std.ArrayList(u16) = .empty,
    aggregate_metrics: std.ArrayList(RuntimeAggregateMetric) = .empty,
    materialized_field_indices: std.ArrayList(u16) = .empty,
    limit_state_count: u16 = 0,
    first_blocking_operation: ?u16 = null,
    aggregate_seen: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        definition_plan: *const definition.Plan,
        native_plan: *const plan.Plan,
        bindings: *const definition_core.parameters.Bindings,
        source_width: usize,
    ) !ProgramBuilder {
        if (source_width == 0 or source_width > 256) {
            return error.InvalidObservationSourceWidth;
        }
        var builder = ProgramBuilder{
            .allocator = allocator,
            .definition_plan = definition_plan,
            .native_plan = native_plan,
            .bindings = bindings,
            .field_map = undefined,
            .field_count = source_width,
        };
        for (builder.field_map[0..source_width], 0..) |*field, index| {
            field.* = @intCast(index);
        }
        return builder;
    }

    fn deinit(self: *ProgramBuilder) void {
        self.predicates.deinit(self.allocator);
        self.operations.deinit(self.allocator);
        self.sort_keys.deinit(self.allocator);
        self.distinct_fields.deinit(self.allocator);
        self.aggregate_metrics.deinit(self.allocator);
        self.materialized_field_indices.deinit(self.allocator);
        self.* = undefined;
    }

    fn applyStage(self: *ProgramBuilder, stage: *const plan.Stage) !void {
        switch (stage.operation) {
            .scan, .alias => {},
            .filter => |filter| try self.applyFilter(filter),
            .project => |project| try self.applyProject(project),
            .limit => |limit| try self.applyLimit(limit),
            .sort => |sort| try self.applySort(sort),
            .top_k => |top_k| try self.applyTopK(top_k),
            .distinct => |distinct| try self.applyDistinct(distinct),
            .aggregate => |aggregate| {
                try self.applyAggregate(aggregate, stage);
            },
            .generic => return error.ObservationGraphOperatorRequiresGraphExecutor,
        }
    }

    fn requireStreaming(self: ProgramBuilder) !void {
        if (self.aggregate_seen) {
            return error.ObservationAggregateMustBeTerminal;
        }
    }

    fn markBlocking(self: *ProgramBuilder) !void {
        if (self.first_blocking_operation == null) {
            self.first_blocking_operation =
                @intCast(self.operations.items.len);
            try self.materialized_field_indices.appendSlice(
                self.allocator,
                self.field_map[0..self.field_count],
            );
            for (self.field_map[0..self.field_count], 0..) |*field, index| {
                field.* = @intCast(index);
            }
        }
    }

    fn applyFilter(
        self: *ProgramBuilder,
        filter: plan.Filter,
    ) !void {
        try self.requireStreaming();
        const start = self.predicates.items.len;
        for (filter.predicates) |predicate| {
            if (predicate.field_index >= self.field_count) {
                return error.ObservationFieldIndexInvalid;
            }
            try self.predicates.append(self.allocator, .{
                .field_index = self.field_map[predicate.field_index],
                .operator = predicate.operator,
                .operand = try resolveOperand(
                    self.definition_plan,
                    self.bindings,
                    predicate.operand,
                ),
                .case_insensitive = predicate.case_insensitive,
            });
        }
        try self.operations.append(
            self.allocator,
            switch (filter.mode) {
                .all => .{ .filter_all = .{
                    .start = @intCast(start),
                    .len = @intCast(self.predicates.items.len - start),
                } },
                .any => .{ .filter_any = .{
                    .start = @intCast(start),
                    .len = @intCast(self.predicates.items.len - start),
                } },
            },
        );
    }

    fn applyProject(
        self: *ProgramBuilder,
        project: plan.Project,
    ) !void {
        var projected: [256]u16 = undefined;
        if (project.input_field_indices.len > projected.len) {
            return error.InvalidProjectionFieldCount;
        }
        for (project.input_field_indices, 0..) |field_index, index| {
            if (field_index >= self.field_count) {
                return error.ObservationFieldIndexInvalid;
            }
            projected[index] = self.field_map[field_index];
        }
        self.field_count = project.input_field_indices.len;
        @memcpy(
            self.field_map[0..self.field_count],
            projected[0..self.field_count],
        );
    }

    fn applyLimit(self: *ProgramBuilder, limit: plan.Limit) !void {
        try self.requireStreaming();
        if (self.limit_state_count == 256 or
            @as(usize, self.limit_state_count) + 1 +
                self.aggregate_metrics.items.len >
                self.definition_plan.bounds.max_fold_states)
        {
            return error.TooManyObservationLimits;
        }
        try self.operations.append(self.allocator, .{
            .limit = .{
                .count = try resolveLimit(
                    self.definition_plan,
                    self.bindings,
                    limit,
                    self.native_plan.max_rows,
                ),
                .state_index = self.limit_state_count,
            },
        });
        self.limit_state_count += 1;
    }

    fn appendSortKeys(
        self: *ProgramBuilder,
        keys: []const plan.SortKey,
    ) !FieldRange {
        const start = self.sort_keys.items.len;
        for (keys) |key| {
            if (key.field_index >= self.field_count) {
                return error.ObservationFieldIndexInvalid;
            }
            try self.sort_keys.append(self.allocator, .{
                .field_index = self.field_map[key.field_index],
                .direction = key.direction,
                .nulls = key.nulls,
            });
        }
        return .{
            .start = @intCast(start),
            .len = @intCast(self.sort_keys.items.len - start),
        };
    }

    fn applySort(self: *ProgramBuilder, sort: plan.Sort) !void {
        try self.requireStreaming();
        try self.markBlocking();
        const keys = try self.appendSortKeys(sort.keys);
        try self.operations.append(self.allocator, .{ .sort = keys });
    }

    fn applyTopK(self: *ProgramBuilder, top_k: plan.TopK) !void {
        try self.requireStreaming();
        try self.markBlocking();
        const keys = try self.appendSortKeys(top_k.keys);
        try self.operations.append(self.allocator, .{
            .top_k = .{
                .keys = keys,
                .count = try resolveLimit(
                    self.definition_plan,
                    self.bindings,
                    top_k.limit,
                    self.native_plan.max_rows,
                ),
            },
        });
    }

    fn applyDistinct(
        self: *ProgramBuilder,
        distinct: plan.Distinct,
    ) !void {
        try self.requireStreaming();
        try self.markBlocking();
        const start = self.distinct_fields.items.len;
        for (distinct.field_indices) |field_index| {
            if (field_index >= self.field_count) {
                return error.ObservationFieldIndexInvalid;
            }
            try self.distinct_fields.append(
                self.allocator,
                self.field_map[field_index],
            );
        }
        try self.operations.append(self.allocator, .{
            .distinct = .{
                .start = @intCast(start),
                .len = @intCast(self.distinct_fields.items.len - start),
            },
        });
    }

    fn applyAggregate(
        self: *ProgramBuilder,
        aggregate: plan.Aggregate,
        stage: *const plan.Stage,
    ) !void {
        try self.requireStreaming();
        if (self.first_blocking_operation != null) {
            return error.ObservationAggregateRequiresStreamingPrefix;
        }
        if (@as(usize, self.limit_state_count) +
            self.aggregate_metrics.items.len + aggregate.metrics.len >
            self.definition_plan.bounds.max_fold_states)
        {
            return error.ObservationFoldStateBoundExceeded;
        }
        const start = self.aggregate_metrics.items.len;
        for (aggregate.metrics, 0..) |metric, metric_index| {
            if (metric.field_index) |field_index| {
                if (field_index >= self.field_count) {
                    return error.ObservationFieldIndexInvalid;
                }
            }
            try self.aggregate_metrics.append(self.allocator, .{
                .function = metric.function,
                .field_index = if (metric.field_index) |field_index|
                    self.field_map[field_index]
                else
                    null,
                .output_kind = stage.schema.columns[metric_index].kind,
            });
        }
        try self.operations.append(self.allocator, .{
            .aggregate = .{
                .start = @intCast(start),
                .len = @intCast(
                    self.aggregate_metrics.items.len - start,
                ),
            },
        });
        self.field_count = aggregate.metrics.len;
        for (self.field_map[0..self.field_count], 0..) |*field, index| {
            field.* = @intCast(index);
        }
        self.aggregate_seen = true;
    }

    fn finish(
        self: *ProgramBuilder,
        resolved: *const ResolvedSource,
        projection: *const plan.Projection,
    ) !Program {
        const source_fields = try self.sourceFields(resolved);
        errdefer self.allocator.free(source_fields);
        const materialized_fields =
            try self.materialized_field_indices.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(materialized_fields);
        const output_fields = try self.outputFields(projection);
        errdefer self.allocator.free(output_fields);
        const operation_slice =
            try self.operations.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(operation_slice);
        const predicate_slice =
            try self.predicates.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(predicate_slice);
        const sort_key_slice =
            try self.sort_keys.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(sort_key_slice);
        const distinct_field_slice =
            try self.distinct_fields.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(distinct_field_slice);
        const aggregate_metric_slice =
            try self.aggregate_metrics.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(aggregate_metric_slice);
        return .{
            .source = resolved.source,
            .source_width = @intCast(resolved.source_width),
            .source_field_indices = source_fields,
            .materialized_field_indices = materialized_fields,
            .source_row_bound = resolved.source_row_bound,
            .operations = operation_slice,
            .predicates = predicate_slice,
            .sort_keys = sort_key_slice,
            .distinct_fields = distinct_field_slice,
            .aggregate_metrics = aggregate_metric_slice,
            .output_field_indices = output_fields,
            .limit_state_count = self.limit_state_count,
            .first_blocking_operation = self.first_blocking_operation,
            .max_rows = self.native_plan.max_rows,
        };
    }

    fn sourceFields(
        self: ProgramBuilder,
        resolved: *const ResolvedSource,
    ) ![]u16 {
        const fields = try self.allocator.alloc(
            u16,
            resolved.source_width,
        );
        if (resolved.physical_field_indices) |indices| {
            @memcpy(fields, indices);
        } else {
            for (fields, 0..) |*field, index| field.* = @intCast(index);
        }
        return fields;
    }

    fn outputFields(
        self: ProgramBuilder,
        projection: *const plan.Projection,
    ) ![]u16 {
        const fields = try self.allocator.alloc(
            u16,
            projection.field_indices.len,
        );
        errdefer self.allocator.free(fields);
        for (projection.field_indices, 0..) |field_index, index| {
            if (field_index >= self.field_count) {
                return error.ObservationFieldIndexInvalid;
            }
            fields[index] = self.field_map[field_index];
        }
        return fields;
    }
};

pub const Feed = enum {
    continue_scanning,
    stop,
};

const max_materialized_cells: usize = 4_000_000;

const RowRef = struct {
    row_index: usize,
    ordinal: usize,
};

const AggregateState = struct {
    count: u64 = 0,
    integer: i64 = 0,
    float: f64 = 0,
    seen: bool = false,
};

pub const Runner = struct {
    program: *const Program,
    output: []Value,
    allocator: ?std.mem.Allocator = null,
    value_allocator: ?std.mem.Allocator = null,
    owned_values: std.ArrayList([]u8) = .empty,
    top_k_owned_values: []std.ArrayList([]u8) = &.{},
    owned_value_bytes: usize = 0,
    owned_value_bytes_max: ?usize = null,
    materialized: []Value = &.{},
    row_refs: []RowRef = &.{},
    auxiliary_refs: []RowRef = &.{},
    duplicate_marks: []bool = &.{},
    limit_states: [256]usize = undefined,
    aggregate_states: [64]AggregateState = undefined,
    aggregate_row: [64]Value = undefined,
    source_row_count: usize = 0,
    materialized_row_count: usize = 0,
    output_row_count: usize = 0,
    stopped: bool = false,
    finalized: bool = false,

    pub fn init(program: *const Program, output: []Value) !Runner {
        try validateRunnerInputs(program);
        if (program.first_blocking_operation != null) {
            return error.ObservationMaterializationWorkspaceRequired;
        }
        var runner = Runner{
            .program = program,
            .output = output,
        };
        @memset(runner.limit_states[0..program.limit_state_count], 0);
        for (
            runner.aggregate_states[0..program.aggregate_metrics.len],
        ) |*state| state.* = .{};
        return runner;
    }

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        program: *const Program,
        output: []Value,
    ) !Runner {
        try validateRunnerInputs(program);
        if (program.first_blocking_operation == null) {
            return init(program, output);
        }
        const row_capacity = materializationRowCapacity(program);
        const materialized_width = program.materialized_field_indices.len;
        const materialized_cells = std.math.mul(
            usize,
            row_capacity,
            materialized_width,
        ) catch return error.ObservationMaterializationCellBoundExceeded;
        if (materialized_cells > max_materialized_cells) {
            return error.ObservationMaterializationCellBoundExceeded;
        }
        const materialized = try allocator.alloc(
            Value,
            materialized_cells,
        );
        errdefer allocator.free(materialized);
        const row_refs = try allocator.alloc(RowRef, row_capacity);
        errdefer allocator.free(row_refs);
        const auxiliary_refs = try allocator.alloc(
            RowRef,
            row_capacity,
        );
        errdefer allocator.free(auxiliary_refs);
        const duplicate_marks = try allocator.alloc(
            bool,
            row_capacity,
        );
        errdefer allocator.free(duplicate_marks);
        var runner = Runner{
            .program = program,
            .output = output,
            .allocator = allocator,
            .materialized = materialized,
            .row_refs = row_refs,
            .auxiliary_refs = auxiliary_refs,
            .duplicate_marks = duplicate_marks,
        };
        @memset(runner.limit_states[0..program.limit_state_count], 0);
        for (
            runner.aggregate_states[0..program.aggregate_metrics.len],
        ) |*state| state.* = .{};
        return runner;
    }

    pub fn initOwnedAlloc(
        allocator: std.mem.Allocator,
        program: *const Program,
        output: []Value,
    ) !Runner {
        return initOwnedAllocBounded(
            allocator,
            program,
            output,
            std.math.maxInt(usize),
        );
    }

    pub fn initOwnedAllocBounded(
        allocator: std.mem.Allocator,
        program: *const Program,
        output: []Value,
        owned_value_bytes_max: usize,
    ) !Runner {
        if (owned_value_bytes_max == 0) {
            return error.ObservationRetainedValueByteBoundInvalid;
        }
        var runner = try initAlloc(allocator, program, output);
        errdefer runner.deinit();
        runner.value_allocator = allocator;
        runner.owned_value_bytes_max = owned_value_bytes_max;
        if (streamingTopK(program) != null) {
            runner.top_k_owned_values = try allocator.alloc(
                std.ArrayList([]u8),
                runner.row_refs.len,
            );
            @memset(runner.top_k_owned_values, .empty);
        }
        return runner;
    }

    pub fn deinit(self: *Runner) void {
        if (self.allocator) |allocator| {
            allocator.free(self.materialized);
            allocator.free(self.row_refs);
            allocator.free(self.auxiliary_refs);
            allocator.free(self.duplicate_marks);
        }
        if (self.value_allocator) |allocator| {
            for (self.top_k_owned_values) |*values| {
                for (values.items) |value| allocator.free(value);
                values.deinit(allocator);
            }
            if (self.top_k_owned_values.len != 0) {
                allocator.free(self.top_k_owned_values);
            }
            for (self.owned_values.items) |value| allocator.free(value);
            self.owned_values.deinit(allocator);
        }
        self.* = undefined;
    }

    pub fn feed(self: *Runner, row: []const Value) !Feed {
        if (self.stopped) return .stop;
        if (self.finalized) return error.ObservationAlreadyFinalized;
        if (row.len != self.program.source_width) {
            return error.ObservationSourceWidthMismatch;
        }
        if (self.program.source_row_bound) |bound| {
            if (self.source_row_count >= bound) {
                return error.ObservationSourceRowBoundExceeded;
            }
        }
        self.source_row_count += 1;

        const operation_end = self.program.first_blocking_operation orelse
            self.program.operations.len;
        const disposition = try self.applyStreaming(
            row,
            self.program.operations[0..operation_end],
        );
        if (disposition.accepted) {
            if (streamingTopK(self.program)) |top_k| {
                try self.materializeTopK(
                    row,
                    top_k,
                    self.source_row_count - 1,
                );
            } else if (self.program.first_blocking_operation != null) {
                try self.materialize(row);
            } else {
                try self.append(row);
            }
        }
        if (disposition.stop_after_row) {
            self.stopped = true;
            return .stop;
        }
        return .continue_scanning;
    }

    pub fn finish(self: *Runner) !Result {
        if (self.finalized) return self.currentResult();
        if (self.program.first_blocking_operation) |start| {
            var active_count = self.materialized_row_count;
            for (self.row_refs[0..active_count], 0..) |*ref, index| {
                ref.row_index = index;
                if (streamingTopK(self.program) == null) {
                    ref.ordinal = index;
                }
            }
            for (self.program.operations[start..]) |operation| {
                active_count = switch (operation) {
                    .filter_all => |range| self.filterRows(
                        active_count,
                        range,
                        .all,
                    ),
                    .filter_any => |range| self.filterRows(
                        active_count,
                        range,
                        .any,
                    ),
                    .limit => |limit| @min(active_count, limit.count),
                    .sort => |range| self.sortRows(active_count, range),
                    .top_k => |top_k| @min(
                        self.sortRows(active_count, top_k.keys),
                        top_k.count,
                    ),
                    .distinct => |range| self.distinctRows(
                        active_count,
                        range,
                    ),
                    .aggregate => return error.ObservationAggregateAfterBlocking,
                };
                resetOrdinals(self.row_refs[0..active_count]);
            }
            for (self.row_refs[0..active_count]) |ref| {
                try self.append(self.materializedRow(ref.row_index));
            }
        } else if (self.program.aggregate_metrics.len != 0) {
            try self.finalizeAggregates();
            try self.append(
                self.aggregate_row[0..self.program.aggregate_metrics.len],
            );
        }
        self.finalized = true;
        return self.currentResult();
    }

    fn currentResult(self: *Runner) Result {
        return .{
            .values = self.output,
            .width = self.program.output_field_indices.len,
            .row_count = self.output_row_count,
            .source_row_count = self.source_row_count,
            .materialized_row_count = self.materialized_row_count,
        };
    }

    const StreamingDisposition = struct {
        accepted: bool,
        stop_after_row: bool,
    };

    fn applyStreaming(
        self: *Runner,
        row: []const Value,
        operations: []const RuntimeOperation,
    ) !StreamingDisposition {
        var accepted = true;
        var stop_after_row = false;
        for (operations) |operation| {
            switch (operation) {
                .filter_all => |range| {
                    if (!self.rowMatches(row, range, .all)) {
                        accepted = false;
                        break;
                    }
                },
                .filter_any => |range| {
                    if (!self.rowMatches(row, range, .any)) {
                        accepted = false;
                        break;
                    }
                },
                .limit => |limit| {
                    if (self.limit_states[limit.state_index] == limit.count) {
                        self.stopped = true;
                        return .{
                            .accepted = false,
                            .stop_after_row = true,
                        };
                    }
                    self.limit_states[limit.state_index] += 1;
                    stop_after_row = stop_after_row or
                        self.limit_states[limit.state_index] == limit.count;
                },
                .sort, .top_k, .distinct => {
                    return error.ObservationBlockingOperatorInStreamingPrefix;
                },
                .aggregate => |range| {
                    try self.accumulateAggregates(row, range);
                    accepted = false;
                    break;
                },
            }
        }
        return .{
            .accepted = accepted,
            .stop_after_row = stop_after_row,
        };
    }

    fn rowMatches(
        self: *const Runner,
        row: []const Value,
        range: PredicateRange,
        mode: plan.FilterMode,
    ) bool {
        const end = @as(usize, range.start) + range.len;
        return switch (mode) {
            .all => all: {
                for (self.program.predicates[range.start..end]) |predicate| {
                    if (!matches(row[predicate.field_index], predicate)) {
                        break :all false;
                    }
                }
                break :all true;
            },
            .any => any: {
                for (self.program.predicates[range.start..end]) |predicate| {
                    if (matches(row[predicate.field_index], predicate)) {
                        break :any true;
                    }
                }
                break :any false;
            },
        };
    }

    fn materializeTopK(
        self: *Runner,
        row: []const Value,
        top_k: RuntimeTopK,
        ordinal: usize,
    ) !void {
        const capacity = self.row_refs.len;
        if (capacity == 0) return;
        const keys = sortKeySlice(self.program, top_k.keys);
        if (self.materialized_row_count < capacity) {
            const index = self.materialized_row_count;
            try self.materializeTopKAt(index, row);
            const reference = RowRef{
                .row_index = index,
                .ordinal = ordinal,
            };
            self.row_refs[index] = reference;
            self.auxiliary_refs[index] = reference;
            self.materialized_row_count += 1;
            self.topKHeapSiftUp(index, keys);
            return;
        }
        const worst_index = self.auxiliary_refs[0].row_index;
        if (!rowSortsBefore(
            row,
            ordinal,
            self.materializedRow(worst_index),
            self.row_refs[worst_index].ordinal,
            keys,
        )) return;
        self.releaseTopKAt(worst_index);
        try self.materializeTopKAt(worst_index, row);
        self.row_refs[worst_index].ordinal = ordinal;
        self.auxiliary_refs[0] = self.row_refs[worst_index];
        self.topKHeapSiftDown(keys);
    }

    fn topKHeapSiftUp(
        self: *Runner,
        initial_index: usize,
        keys: []const RuntimeSortKey,
    ) void {
        var index = initial_index;
        while (index != 0) {
            const parent = (index - 1) / 2;
            if (!self.topKRefSortsBefore(
                self.auxiliary_refs[parent],
                self.auxiliary_refs[index],
                keys,
            )) return;
            std.mem.swap(
                RowRef,
                &self.auxiliary_refs[parent],
                &self.auxiliary_refs[index],
            );
            index = parent;
        }
    }

    fn topKHeapSiftDown(
        self: *Runner,
        keys: []const RuntimeSortKey,
    ) void {
        var index: usize = 0;
        var remaining = self.materialized_row_count;
        while (remaining > 0) : (remaining -= 1) {
            const left = index * 2 + 1;
            if (left >= self.materialized_row_count) return;
            const right = left + 1;
            const worse_child = if (right < self.materialized_row_count and
                self.topKRefSortsBefore(
                    self.auxiliary_refs[left],
                    self.auxiliary_refs[right],
                    keys,
                ))
                right
            else
                left;
            if (!self.topKRefSortsBefore(
                self.auxiliary_refs[index],
                self.auxiliary_refs[worse_child],
                keys,
            )) return;
            std.mem.swap(
                RowRef,
                &self.auxiliary_refs[index],
                &self.auxiliary_refs[worse_child],
            );
            index = worse_child;
        }
    }

    fn topKRefSortsBefore(
        self: *const Runner,
        left: RowRef,
        right: RowRef,
        keys: []const RuntimeSortKey,
    ) bool {
        return rowSortsBefore(
            self.materializedRow(left.row_index),
            left.ordinal,
            self.materializedRow(right.row_index),
            right.ordinal,
            keys,
        );
    }

    fn materializeTopKAt(
        self: *Runner,
        index: usize,
        row: []const Value,
    ) !void {
        const destination = self.materializedRowMut(index);
        if (self.value_allocator == null) {
            for (
                self.program.materialized_field_indices,
                destination,
            ) |source_index, *value| value.* = row[source_index];
            return;
        }
        errdefer self.releaseTopKAt(index);
        for (
            self.program.materialized_field_indices,
            destination,
        ) |source_index, *value| {
            value.* = try self.retainTopKValue(
                index,
                row[source_index],
            );
        }
    }

    fn retainTopKValue(
        self: *Runner,
        index: usize,
        value: Value,
    ) !Value {
        return switch (value) {
            .string => |text| .{
                .string = try self.retainTopKBytes(index, text),
            },
            .json => |json| .{
                .json = try self.retainTopKBytes(index, json),
            },
            else => value,
        };
    }

    fn retainTopKBytes(
        self: *Runner,
        index: usize,
        bytes: []const u8,
    ) ![]const u8 {
        const allocator = self.value_allocator orelse unreachable;
        const new_total = std.math.add(
            usize,
            self.owned_value_bytes,
            bytes.len,
        ) catch return error.ObservationRetainedValueByteBoundExceeded;
        if (self.owned_value_bytes_max) |max_bytes| {
            if (new_total > max_bytes) {
                return error.ObservationRetainedValueByteBoundExceeded;
            }
        }
        const copy = try allocator.dupe(u8, bytes);
        errdefer allocator.free(copy);
        try self.top_k_owned_values[index].append(allocator, copy);
        self.owned_value_bytes = new_total;
        return copy;
    }

    fn releaseTopKAt(self: *Runner, index: usize) void {
        if (self.value_allocator) |allocator| {
            const values = &self.top_k_owned_values[index];
            for (values.items) |value| {
                std.debug.assert(self.owned_value_bytes >= value.len);
                self.owned_value_bytes -= value.len;
                allocator.free(value);
            }
            values.clearRetainingCapacity();
        }
    }

    fn materialize(self: *Runner, row: []const Value) !void {
        if (self.materialized_row_count == self.program.max_rows) {
            return error.ObservationMaterializationRowBoundExceeded;
        }
        const width = self.program.materialized_field_indices.len;
        const destination = self.materialized[self.materialized_row_count * width ..][0..width];
        if (self.value_allocator != null) {
            for (
                self.program.materialized_field_indices,
                destination,
            ) |source_index, *value| {
                value.* = try self.retainValue(row[source_index]);
            }
        } else {
            for (
                self.program.materialized_field_indices,
                destination,
            ) |source_index, *value| value.* = row[source_index];
        }
        self.materialized_row_count += 1;
    }

    fn accumulateAggregates(
        self: *Runner,
        row: []const Value,
        range: FieldRange,
    ) !void {
        const end = @as(usize, range.start) + range.len;
        for (
            self.program.aggregate_metrics[range.start..end],
            self.aggregate_states[range.start..end],
        ) |metric, *state| {
            const value = if (metric.field_index) |field| value: {
                if (row[field] == .null) continue;
                break :value row[field];
            } else {
                if (metric.function != .count) {
                    return error.ObservationAggregateFieldRequired;
                }
                state.count = std.math.add(
                    u64,
                    state.count,
                    1,
                ) catch return error.ObservationAggregateOverflow;
                continue;
            };
            switch (metric.function) {
                .count => {
                    state.count = std.math.add(
                        u64,
                        state.count,
                        1,
                    ) catch return error.ObservationAggregateOverflow;
                },
                .sum => try accumulateSum(metric, state, value),
                .average => {
                    try accumulateFloat(state, value);
                    state.count = std.math.add(
                        u64,
                        state.count,
                        1,
                    ) catch return error.ObservationAggregateOverflow;
                },
                .min => try accumulateExtremum(
                    metric,
                    state,
                    value,
                    .min,
                ),
                .max => try accumulateExtremum(
                    metric,
                    state,
                    value,
                    .max,
                ),
            }
        }
    }

    fn finalizeAggregates(self: *Runner) !void {
        for (
            self.program.aggregate_metrics,
            self.aggregate_states[0..self.program.aggregate_metrics.len],
            0..,
        ) |metric, state, index| {
            self.aggregate_row[index] = switch (metric.function) {
                .count => .{ .integer = std.math.cast(
                    i64,
                    state.count,
                ) orelse return error.ObservationAggregateOverflow },
                .sum => switch (metric.output_kind) {
                    .integer => .{ .integer = state.integer },
                    .float => .{ .float = state.float },
                    else => return error.ObservationAggregateTypeMismatch,
                },
                .average => if (state.count == 0)
                    .null
                else
                    .{ .float = state.float / @as(f64, @floatFromInt(
                        state.count,
                    )) },
                .min, .max => if (!state.seen)
                    .null
                else switch (metric.output_kind) {
                    .integer => .{ .integer = state.integer },
                    .float => .{ .float = state.float },
                    else => return error.ObservationAggregateTypeMismatch,
                },
            };
        }
    }

    fn materializedRow(
        self: *const Runner,
        row_index: usize,
    ) []const Value {
        const width = self.program.materialized_field_indices.len;
        const start = row_index * width;
        return self.materialized[start..][0..width];
    }

    fn materializedRowMut(
        self: *Runner,
        row_index: usize,
    ) []Value {
        const width = self.program.materialized_field_indices.len;
        const start = row_index * width;
        return self.materialized[start..][0..width];
    }

    fn filterRows(
        self: *Runner,
        active_count: usize,
        range: PredicateRange,
        mode: plan.FilterMode,
    ) usize {
        var output_index: usize = 0;
        for (self.row_refs[0..active_count]) |ref| {
            if (!self.rowMatches(
                self.materializedRow(ref.row_index),
                range,
                mode,
            )) continue;
            self.row_refs[output_index] = ref;
            output_index += 1;
        }
        return output_index;
    }

    fn sortRows(
        self: *Runner,
        active_count: usize,
        range: FieldRange,
    ) usize {
        const end = @as(usize, range.start) + range.len;
        std.mem.sort(
            RowRef,
            self.row_refs[0..active_count],
            SortContext{
                .runner = self,
                .keys = self.program.sort_keys[range.start..end],
            },
            SortContext.lessThan,
        );
        return active_count;
    }

    fn distinctRows(
        self: *Runner,
        active_count: usize,
        range: FieldRange,
    ) usize {
        if (active_count < 2) return active_count;
        @memcpy(
            self.auxiliary_refs[0..active_count],
            self.row_refs[0..active_count],
        );
        const end = @as(usize, range.start) + range.len;
        const fields = self.program.distinct_fields[range.start..end];
        std.mem.sort(
            RowRef,
            self.auxiliary_refs[0..active_count],
            DistinctContext{
                .runner = self,
                .fields = fields,
            },
            DistinctContext.lessThan,
        );
        @memset(self.duplicate_marks[0..active_count], false);
        var prior = self.auxiliary_refs[0];
        for (self.auxiliary_refs[1..active_count]) |current| {
            if (distinctKeysEqual(self, prior, current, fields)) {
                self.duplicate_marks[current.ordinal] = true;
            } else {
                prior = current;
            }
        }
        var output_index: usize = 0;
        for (self.row_refs[0..active_count]) |ref| {
            if (self.duplicate_marks[ref.ordinal]) continue;
            self.row_refs[output_index] = ref;
            output_index += 1;
        }
        return output_index;
    }

    fn append(self: *Runner, row: []const Value) !void {
        if (self.output_row_count == self.program.max_rows) {
            return error.ObservationRowBoundExceeded;
        }
        const output_width = self.program.output_field_indices.len;
        const output_start = std.math.mul(
            usize,
            self.output_row_count,
            output_width,
        ) catch return error.ObservationOutputSizeOverflow;
        const output_end = std.math.add(
            usize,
            output_start,
            output_width,
        ) catch return error.ObservationOutputSizeOverflow;
        if (output_end > self.output.len) {
            return error.ObservationOutputBufferTooSmall;
        }
        for (self.program.output_field_indices, 0..) |field_index, index| {
            self.output[output_start + index] =
                if (self.value_allocator != null and
                self.program.first_blocking_operation == null)
                    try self.retainValue(row[field_index])
                else
                    row[field_index];
        }
        self.output_row_count += 1;
    }

    fn retainValue(self: *Runner, value: Value) !Value {
        const allocator = self.value_allocator orelse return value;
        return switch (value) {
            .string => |text| .{
                .string = try self.retainBytes(allocator, text),
            },
            .json => |json| .{
                .json = try self.retainBytes(allocator, json),
            },
            else => value,
        };
    }

    fn retainBytes(
        self: *Runner,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) ![]const u8 {
        const new_total = std.math.add(
            usize,
            self.owned_value_bytes,
            bytes.len,
        ) catch return error.ObservationRetainedValueByteBoundExceeded;
        if (self.owned_value_bytes_max) |max_bytes| {
            if (new_total > max_bytes) {
                return error.ObservationRetainedValueByteBoundExceeded;
            }
        }
        const copy = try allocator.dupe(u8, bytes);
        errdefer allocator.free(copy);
        try self.owned_values.append(allocator, copy);
        self.owned_value_bytes = new_total;
        return copy;
    }
};

fn accumulateSum(
    metric: RuntimeAggregateMetric,
    state: *AggregateState,
    value: Value,
) !void {
    switch (metric.output_kind) {
        .integer => {
            const integer = switch (value) {
                .integer => |number| number,
                else => return error.ObservationAggregateTypeMismatch,
            };
            state.integer = std.math.add(
                i64,
                state.integer,
                integer,
            ) catch return error.ObservationAggregateOverflow;
        },
        .float => try accumulateFloat(state, value),
        else => return error.ObservationAggregateTypeMismatch,
    }
}

fn accumulateFloat(state: *AggregateState, value: Value) !void {
    const number: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return error.ObservationAggregateTypeMismatch,
    };
    const sum = state.float + number;
    if (!std.math.isFinite(sum)) return error.ObservationAggregateOverflow;
    state.float = sum;
}

const Extremum = enum { min, max };

fn accumulateExtremum(
    metric: RuntimeAggregateMetric,
    state: *AggregateState,
    value: Value,
    extremum: Extremum,
) !void {
    switch (metric.output_kind) {
        .integer => {
            const number = switch (value) {
                .integer => |integer| integer,
                else => return error.ObservationAggregateTypeMismatch,
            };
            if (!state.seen or
                (extremum == .min and number < state.integer) or
                (extremum == .max and number > state.integer))
            {
                state.integer = number;
            }
        },
        .float => {
            const number: f64 = switch (value) {
                .integer => |integer| @floatFromInt(integer),
                .float => |float| float,
                else => return error.ObservationAggregateTypeMismatch,
            };
            if (!std.math.isFinite(number)) {
                return error.ObservationAggregateTypeMismatch;
            }
            if (!state.seen or
                (extremum == .min and number < state.float) or
                (extremum == .max and number > state.float))
            {
                state.float = number;
            }
        },
        else => return error.ObservationAggregateTypeMismatch,
    }
    state.seen = true;
}

fn validateRunnerInputs(program: *const Program) !void {
    if (program.source_width == 0) {
        return error.InvalidObservationSourceWidth;
    }
    if (program.output_field_indices.len == 0) {
        return error.InvalidObservationOutputWidth;
    }
    if (program.first_blocking_operation != null and
        program.materialized_field_indices.len == 0)
    {
        return error.InvalidObservationMaterializedWidth;
    }
}

fn streamingTopK(program: *const Program) ?RuntimeTopK {
    const index = program.first_blocking_operation orelse return null;
    return switch (program.operations[index]) {
        .top_k => |top_k| top_k,
        else => null,
    };
}

fn materializationRowCapacity(program: *const Program) usize {
    const top_k = streamingTopK(program) orelse return program.max_rows;
    return @min(program.max_rows, top_k.count);
}

fn resetOrdinals(refs: []RowRef) void {
    for (refs, 0..) |*ref, index| ref.ordinal = index;
}

fn sortKeySlice(
    program: *const Program,
    range: FieldRange,
) []const RuntimeSortKey {
    const end = @as(usize, range.start) + range.len;
    return program.sort_keys[range.start..end];
}

fn rowSortsBefore(
    left_row: []const Value,
    left_ordinal: usize,
    right_row: []const Value,
    right_ordinal: usize,
    keys: []const RuntimeSortKey,
) bool {
    for (keys) |key| {
        const left_value = left_row[key.field_index];
        const right_value = right_row[key.field_index];
        const order = compareForSort(
            left_value,
            right_value,
            key.nulls,
        );
        if (order == .eq) continue;
        if (left_value == .null or right_value == .null) {
            return order == .lt;
        }
        return if (key.direction == .ascending)
            order == .lt
        else
            order == .gt;
    }
    return left_ordinal < right_ordinal;
}

const SortContext = struct {
    runner: *const Runner,
    keys: []const RuntimeSortKey,

    fn lessThan(context: SortContext, left: RowRef, right: RowRef) bool {
        return rowSortsBefore(
            context.runner.materializedRow(left.row_index),
            left.ordinal,
            context.runner.materializedRow(right.row_index),
            right.ordinal,
            context.keys,
        );
    }
};

const DistinctContext = struct {
    runner: *const Runner,
    fields: []const u16,

    fn lessThan(context: DistinctContext, left: RowRef, right: RowRef) bool {
        const left_row = context.runner.materializedRow(left.row_index);
        const right_row = context.runner.materializedRow(right.row_index);
        for (context.fields) |field_index| {
            const order = compareValues(
                left_row[field_index],
                right_row[field_index],
            );
            if (order != .eq) return order == .lt;
        }
        return left.ordinal < right.ordinal;
    }
};

fn distinctKeysEqual(
    runner: *const Runner,
    left: RowRef,
    right: RowRef,
    fields: []const u16,
) bool {
    const left_row = runner.materializedRow(left.row_index);
    const right_row = runner.materializedRow(right.row_index);
    for (fields) |field_index| {
        if (!valuesEqual(
            left_row[field_index],
            right_row[field_index],
            false,
        )) return false;
    }
    return true;
}

fn compareForSort(
    left: Value,
    right: Value,
    nulls: plan.NullOrder,
) std.math.Order {
    if (left == .null or right == .null) {
        if (left == .null and right == .null) return .eq;
        const left_first = nulls == .first;
        return if (left == .null)
            if (left_first) .lt else .gt
        else if (left_first)
            .gt
        else
            .lt;
    }
    return compareValues(left, right);
}

fn compareValues(left: Value, right: Value) std.math.Order {
    return switch (left) {
        .string => |left_text| switch (right) {
            .string => |right_text| std.mem.order(
                u8,
                left_text,
                right_text,
            ),
            else => compareValueTags(left, right),
        },
        .integer => |left_number| switch (right) {
            .integer => |right_number| std.math.order(
                left_number,
                right_number,
            ),
            .float => |right_number| compareIntegerFloat(
                left_number,
                right_number,
            ),
            else => compareValueTags(left, right),
        },
        .float => |left_number| switch (right) {
            .integer => |right_number| switch (compareIntegerFloat(
                right_number,
                left_number,
            )) {
                .lt => .gt,
                .eq => .eq,
                .gt => .lt,
            },
            .float => |right_number| compareFloat(
                left_number,
                right_number,
            ),
            else => compareValueTags(left, right),
        },
        .boolean => |left_flag| switch (right) {
            .boolean => |right_flag| std.math.order(
                @intFromBool(left_flag),
                @intFromBool(right_flag),
            ),
            else => compareValueTags(left, right),
        },
        .json => |left_json| switch (right) {
            .json => |right_json| std.mem.order(
                u8,
                left_json,
                right_json,
            ),
            else => compareValueTags(left, right),
        },
        .null => if (right == .null) .eq else .lt,
    };
}

fn compareFloat(left: f64, right: f64) std.math.Order {
    if (left < right) return .lt;
    if (left > right) return .gt;
    return .eq;
}

fn compareIntegerFloat(left: i64, right: f64) std.math.Order {
    const integer_min: f64 = -9_223_372_036_854_775_808.0;
    const integer_limit: f64 = 9_223_372_036_854_775_808.0;
    if (right < integer_min) return .gt;
    if (right >= integer_limit) return .lt;
    const truncated: i64 = @intFromFloat(right);
    const integer_order = std.math.order(left, truncated);
    if (integer_order != .eq) return integer_order;
    if (right > 0 and right != @trunc(right)) return .lt;
    if (right < 0 and right != @trunc(right)) return .gt;
    return .eq;
}

fn compareValueTags(left: Value, right: Value) std.math.Order {
    return std.math.order(
        @intFromEnum(std.meta.activeTag(left)),
        @intFromEnum(std.meta.activeTag(right)),
    );
}

pub fn execute(
    program: *const Program,
    source_rows: Rows,
    output: []Value,
) !Result {
    if (program.first_blocking_operation != null) {
        return error.ObservationMaterializationWorkspaceRequired;
    }
    return executeRunner(program, source_rows, output, null);
}

pub fn executeAlloc(
    allocator: std.mem.Allocator,
    program: *const Program,
    source_rows: Rows,
    output: []Value,
) !Result {
    return executeRunner(program, source_rows, output, allocator);
}

fn executeRunner(
    program: *const Program,
    source_rows: Rows,
    output: []Value,
    allocator: ?std.mem.Allocator,
) !Result {
    if (source_rows.width != program.source_width) {
        return error.ObservationSourceWidthMismatch;
    }
    const source_row_count = try source_rows.count();
    var runner = if (allocator) |value|
        try Runner.initAlloc(value, program, output)
    else
        try Runner.init(program, output);
    defer runner.deinit();
    for (0..source_row_count) |row_index| {
        if (try runner.feed(source_rows.row(row_index)) == .stop) break;
    }
    return runner.finish();
}

fn matches(value: Value, predicate: RuntimePredicate) bool {
    const equal = valuesEqual(
        value,
        predicate.operand,
        predicate.case_insensitive,
    );
    return switch (predicate.operator) {
        .exact => equal,
        .not_equal => !equal,
        .contains => stringOperation(
            value,
            predicate.operand,
            predicate.case_insensitive,
            .contains,
        ),
        .prefix => stringOperation(
            value,
            predicate.operand,
            predicate.case_insensitive,
            .prefix,
        ),
        .suffix => stringOperation(
            value,
            predicate.operand,
            predicate.case_insensitive,
            .suffix,
        ),
        .less_than => if (numericOrder(value, predicate.operand)) |order|
            order == .lt
        else
            false,
        .less_or_equal => if (numericOrder(
            value,
            predicate.operand,
        )) |order|
            order == .lt or order == .eq
        else
            false,
        .greater_than => if (numericOrder(value, predicate.operand)) |order|
            order == .gt
        else
            false,
        .greater_or_equal => if (numericOrder(
            value,
            predicate.operand,
        )) |order|
            order == .gt or order == .eq
        else
            false,
    };
}

fn numericOrder(left: Value, right: Value) ?std.math.Order {
    const left_numeric = left == .integer or left == .float;
    const right_numeric = right == .integer or right == .float;
    if (!left_numeric or !right_numeric) return null;
    return compareValues(left, right);
}

const StringOperation = enum { contains, prefix, suffix };

fn stringOperation(
    value: Value,
    operand: Value,
    case_insensitive: bool,
    operation: StringOperation,
) bool {
    const haystack = switch (value) {
        .string => |text| text,
        .json => |text| text,
        else => return false,
    };
    const needle = switch (operand) {
        .string => |text| text,
        else => return false,
    };
    if (!case_insensitive) {
        return switch (operation) {
            .contains => std.mem.indexOf(u8, haystack, needle) != null,
            .prefix => std.mem.startsWith(u8, haystack, needle),
            .suffix => std.mem.endsWith(u8, haystack, needle),
        };
    }
    return switch (operation) {
        .contains => containsIgnoreCase(haystack, needle),
        .prefix => haystack.len >= needle.len and
            std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle),
        .suffix => haystack.len >= needle.len and
            std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle),
    };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(
            haystack[index..][0..needle.len],
            needle,
        )) return true;
    }
    return false;
}

fn valuesEqual(left: Value, right: Value, case_insensitive: bool) bool {
    return switch (left) {
        .string => |left_text| switch (right) {
            .string => |right_text| if (case_insensitive)
                std.ascii.eqlIgnoreCase(left_text, right_text)
            else
                std.mem.eql(u8, left_text, right_text),
            else => false,
        },
        .integer => |left_number| switch (right) {
            .integer => |right_number| left_number == right_number,
            .float => |right_number| compareIntegerFloat(
                left_number,
                right_number,
            ) == .eq,
            else => false,
        },
        .float => |left_number| switch (right) {
            .integer => |right_number| compareIntegerFloat(
                right_number,
                left_number,
            ) == .eq,
            .float => |right_number| left_number == right_number,
            else => false,
        },
        .boolean => |left_flag| switch (right) {
            .boolean => |right_flag| left_flag == right_flag,
            else => false,
        },
        .json => |left_json| switch (right) {
            .json => |right_json| std.mem.eql(u8, left_json, right_json),
            else => false,
        },
        .null => right == .null,
    };
}

fn findProjection(
    projections: []const definition.Projection,
    name: []const u8,
) ?u16 {
    for (projections, 0..) |projection, index| {
        if (std.mem.eql(u8, projection.name, name)) return @intCast(index);
    }
    return null;
}

fn resolveOperand(
    definition_plan: *const definition.Plan,
    bindings: *const definition_core.parameters.Bindings,
    operand: plan.Operand,
) !Value {
    return switch (operand) {
        .constant => |constant| switch (constant) {
            .string => |text| .{ .string = text },
            .integer => |number| .{ .integer = number },
            .float => |number| .{ .float = number },
            .boolean => |flag| .{ .boolean = flag },
            .null => .null,
        },
        .parameter => |index| resolveParameter(
            definition_plan,
            bindings,
            index,
        ),
    };
}

fn resolveParameter(
    definition_plan: *const definition.Plan,
    bindings: *const definition_core.parameters.Bindings,
    index: u16,
) !Value {
    if (index >= definition_plan.parameter_declarations.items.len) {
        return error.ObservationParameterIndexInvalid;
    }
    const name = definition_plan.parameter_declarations.items[index].name;
    for (bindings.items) |binding| {
        if (!std.mem.eql(u8, binding.name, name)) continue;
        return switch (binding.value) {
            .string => |text| .{ .string = text },
            .integer => |number| .{ .integer = number },
            .boolean => |flag| .{ .boolean = flag },
            .digest => |text| .{ .string = text },
            .timestamp => |text| .{ .string = text },
            .safe_identifier => |text| .{ .string = text },
            .relative_path => |text| .{ .string = text },
        };
    }
    return error.MissingObservationParameter;
}

fn resolveLimit(
    definition_plan: *const definition.Plan,
    bindings: *const definition_core.parameters.Bindings,
    limit: plan.Limit,
    max_rows: usize,
) !usize {
    const count = switch (limit) {
        .fixed => |value| value,
        .parameter => |index| switch (try resolveParameter(
            definition_plan,
            bindings,
            index,
        )) {
            .integer => |value| std.math.cast(usize, value) orelse
                return error.InvalidObservationLimit,
            else => return error.ObservationLimitParameterMustBeInteger,
        },
    };
    if (count == 0 or count > max_rows) return error.InvalidObservationLimit;
    return count;
}

fn compileForAllocationFailure(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    bindings: *const definition_core.parameters.Bindings,
) !void {
    var program = try compile(
        allocator,
        definition_plan,
        native_plan,
        bindings,
        "rows",
    );
    defer program.deinit(allocator);
}

const filter_test_definition =
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
    \\    "name":"messages",
    \\    "fields":["session_id","role","text"]
    \\  }],
    \\  "inputs":[],
    \\  "pipeline":[
    \\    {"op":"scan","relation":"messages","as":"source"},
    \\    {
    \\      "op":"filter","input":"source","as":"matched",
    \\      "where_mode":"any",
    \\      "where":[
    \\        {
    \\          "field":"text","op":"contains","param":"needle",
    \\          "case_insensitive":true
    \\        },
    \\        {"field":"role","op":"exact","value":"tool"}
    \\      ]
    \\    },
    \\    {
    \\      "op":"project","input":"matched","as":"rows",
    \\      "fields":["session_id","text"]
    \\    },
    \\    {"op":"limit","input":"rows","as":"bounded","limit":2}
    \\  ],
    \\  "projections":{"rows":{
    \\    "relation":"bounded","schema":"example-message-rows/v1",
    \\    "fields":["session_id","text"],"renderers":["json"]
    \\  }},
    \\  "bounds":{
    \\    "max_rows":100,"max_output_bytes":4096,"max_fold_states":8
    \\  }
    \\}
;

const ordered_limit_test_definition =
    \\{
    \\  "schema":"seq-observation-definition/v1",
    \\  "id":"example/ordered",
    \\  "requires":{
    \\    "abi":"seq-observation-abi/v1",
    \\    "operators":["limit","filter","project"]
    \\  },
    \\  "parameters":{},"selectors":[],"relations":[],
    \\  "inputs":[{
    \\    "name":"facts","schema":"example-facts/v1",
    \\    "fields":[
    \\      {"name":"id","type":"string","nullable":false},
    \\      {"name":"score","type":"integer","nullable":false}
    \\    ],
    \\    "max_rows":3,"max_bytes":4096
    \\  }],
    \\  "pipeline":[
    \\    {"op":"limit","input":"facts","as":"first","limit":2},
    \\    {
    \\      "op":"filter","input":"first","as":"matched",
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
    \\    "max_rows":3,"max_output_bytes":4096,"max_fold_states":2
    \\  }
    \\}
;

const numeric_filter_test_definition =
    \\{
    \\  "schema":"seq-observation-definition/v1",
    \\  "id":"example/numeric-filter",
    \\  "requires":{"abi":"seq-observation-abi/v1",
    \\              "operators":["filter","project"]},
    \\  "parameters":{"through":{"type":"integer","required":true}},
    \\  "selectors":[],"relations":[],
    \\  "inputs":[{
    \\    "name":"facts","schema":"example-facts/v1",
    \\    "fields":[
    \\      {"name":"id","type":"string","nullable":false},
    \\      {"name":"turn_index","type":"integer","nullable":true}
    \\    ],
    \\    "max_rows":8,"max_bytes":4096
    \\  }],
    \\  "pipeline":[
    \\    {"op":"filter","input":"facts","as":"bounded",
    \\     "where":[{"field":"turn_index","op":"less-or-equal",
    \\               "param":"through"}]},
    \\    {"op":"project","input":"bounded","as":"rows","fields":["id"]}
    \\  ],
    \\  "projections":{"rows":{
    \\    "relation":"rows","schema":"example-numeric-rows/v1",
    \\    "fields":["id"],"renderers":["json"]
    \\  }},
    \\  "bounds":{"max_rows":8,"max_output_bytes":4096,
    \\            "max_fold_states":1}
    \\}
;

const sort_distinct_test_definition =
    \\{
    \\  "schema":"seq-observation-definition/v1",
    \\  "id":"example/ranked-distinct",
    \\  "requires":{
    \\    "abi":"seq-observation-abi/v1",
    \\    "operators":["sort","distinct","limit","project"]
    \\  },
    \\  "parameters":{},"selectors":[],"relations":[],
    \\  "inputs":[{
    \\    "name":"facts","schema":"example-facts/v1",
    \\    "fields":[
    \\      {"name":"id","type":"string","nullable":false},
    \\      {"name":"group","type":"string","nullable":false},
    \\      {"name":"score","type":"integer","nullable":true}
    \\    ],
    \\    "max_rows":5,"max_bytes":4096
    \\  }],
    \\  "pipeline":[
    \\    {
    \\      "op":"sort","input":"facts","as":"ranked",
    \\      "by":[{
    \\        "field":"score","direction":"desc","nulls":"last"
    \\      }]
    \\    },
    \\    {
    \\      "op":"distinct","input":"ranked","as":"unique",
    \\      "keys":["group"]
    \\    },
    \\    {"op":"limit","input":"unique","as":"bounded","limit":3},
    \\    {
    \\      "op":"project","input":"bounded","as":"rows",
    \\      "fields":["id","score"]
    \\    }
    \\  ],
    \\  "projections":{"rows":{
    \\    "relation":"rows","schema":"example-ranked/v1",
    \\    "fields":["id","score"],"renderers":["json"]
    \\  }},
    \\  "bounds":{
    \\    "max_rows":5,"max_output_bytes":4096,"max_fold_states":2
    \\  }
    \\}
;

const top_k_test_definition =
    \\{
    \\  "schema":"seq-observation-definition/v1",
    \\  "id":"example/top",
    \\  "requires":{
    \\    "abi":"seq-observation-abi/v1",
    \\    "operators":["top-k","project"]
    \\  },
    \\  "parameters":{"k":{"type":"integer","required":true}},
    \\  "selectors":[],"relations":[],
    \\  "inputs":[{
    \\    "name":"facts","schema":"example-facts/v1",
    \\    "fields":[
    \\      {"name":"id","type":"string","nullable":false},
    \\      {"name":"score","type":"integer","nullable":false}
    \\    ],
    \\    "max_rows":4,"max_bytes":4096
    \\  }],
    \\  "pipeline":[
    \\    {
    \\      "op":"top-k","input":"facts","as":"ranked",
    \\      "by":[{"field":"score","direction":"desc"}],"limit":"k"
    \\    },
    \\    {
    \\      "op":"project","input":"ranked","as":"rows","fields":["id"]
    \\    }
    \\  ],
    \\  "projections":{"rows":{
    \\    "relation":"rows","schema":"example-top/v1",
    \\    "fields":["id"],"renderers":["json"]
    \\  }},
    \\  "bounds":{
    \\    "max_rows":4,"max_output_bytes":4096,"max_fold_states":2
    \\  }
    \\}
;

const aggregate_test_definition =
    \\{
    \\  "schema":"seq-observation-definition/v1",
    \\  "id":"example/aggregate",
    \\  "requires":{
    \\    "abi":"seq-observation-abi/v1","operators":["aggregate"]
    \\  },
    \\  "parameters":{},"selectors":[],"relations":[],
    \\  "inputs":[{
    \\    "name":"facts","schema":"example-facts/v1",
    \\    "fields":[
    \\      {"name":"amount","type":"integer","nullable":true},
    \\      {"name":"score","type":"float","nullable":true}
    \\    ],
    \\    "max_rows":3,"max_bytes":4096
    \\  }],
    \\  "pipeline":[{
    \\    "op":"aggregate","input":"facts","as":"summary",
    \\    "metrics":[
    \\      {"name":"row_count","op":"count"},
    \\      {"name":"observed_amount","op":"count","field":"amount"},
    \\      {"name":"sum_amount","op":"sum","field":"amount"},
    \\      {"name":"min_amount","op":"min","field":"amount"},
    \\      {"name":"max_amount","op":"max","field":"amount"},
    \\      {"name":"avg_amount","op":"average","field":"amount"},
    \\      {"name":"sum_score","op":"sum","field":"score"}
    \\    ]
    \\  }],
    \\  "projections":{"summary":{
    \\    "relation":"summary","schema":"example-summary/v1",
    \\    "fields":[
    \\      "row_count","observed_amount","sum_amount","min_amount",
    \\      "max_amount","avg_amount","sum_score"
    \\    ],
    \\    "renderers":["json"]
    \\  }},
    \\  "bounds":{
    \\    "max_rows":3,"max_output_bytes":4096,"max_fold_states":8
    \\  }
    \\}
;

const TestProgram = struct {
    closure: definition_core.Closure,
    definition_plan: definition.Plan,
    native_plan: plan.Plan,
    bindings: definition_core.parameters.Bindings,
    program: Program,

    fn deinit(self: *TestProgram) void {
        self.program.deinit(std.testing.allocator);
        self.bindings.deinit(std.testing.allocator);
        self.native_plan.deinit(std.testing.allocator);
        self.definition_plan.deinit(std.testing.allocator);
        self.closure.deinit(std.testing.allocator);
        self.* = undefined;
    }
};

fn compileTestProgram(
    directory: *std.Io.Dir,
    definition_bytes: []const u8,
    parameter_inputs: []const definition_core.parameters.Input,
    projection_name: []const u8,
) !TestProgram {
    try directory.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data = definition_bytes,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        directory,
        "observation.json",
        .{},
    );
    errdefer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "observation.json",
    );
    errdefer definition_plan.deinit(std.testing.allocator);
    var native_plan = try plan.compile(
        std.testing.allocator,
        &definition_plan,
    );
    errdefer native_plan.deinit(std.testing.allocator);
    var bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        parameter_inputs,
    );
    errdefer bindings.deinit(std.testing.allocator);
    const program = try compile(
        std.testing.allocator,
        &definition_plan,
        &native_plan,
        &bindings,
        projection_name,
    );
    return .{
        .closure = closure,
        .definition_plan = definition_plan,
        .native_plan = native_plan,
        .bindings = bindings,
        .program = program,
    };
}

fn expectStreamingFilterResult(
    program: *const Program,
    source: []const Value,
    expected: Result,
) !void {
    var output: [4]Value = undefined;
    var runner = try Runner.init(program, &output);
    defer runner.deinit();
    try std.testing.expectEqual(
        Feed.continue_scanning,
        try runner.feed(source[0..3]),
    );
    try std.testing.expectEqual(
        Feed.continue_scanning,
        try runner.feed(source[3..6]),
    );
    try std.testing.expectEqual(
        Feed.stop,
        try runner.feed(source[6..9]),
    );
    try std.testing.expectEqual(Feed.stop, try runner.feed(source[9..12]));
    const streamed = try runner.finish();
    try std.testing.expectEqual(@as(usize, 3), runner.source_row_count);
    try std.testing.expectEqual(expected.row_count, streamed.row_count);
    try std.testing.expectEqualStrings(
        expected.rows().row(0)[0].string,
        streamed.rows().row(0)[0].string,
    );
    try std.testing.expectEqualStrings(
        expected.rows().row(1)[1].string,
        streamed.rows().row(1)[1].string,
    );
}

test "compiled execution filters projects and limits without intermediate rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try compileTestProgram(
        &tmp.dir,
        filter_test_definition,
        &.{.{ .name = "needle", .raw_value = "FAIL" }},
        "rows",
    );
    defer fixture.deinit();
    const program = &fixture.program;
    try std.testing.expectEqualSlices(
        u16,
        &.{ 1, 3, 4 },
        program.source_field_indices,
    );

    const source = [_]Value{
        .{ .string = "s1" }, .{ .string = "assistant" }, .{ .string = "pass" },
        .{ .string = "s2" }, .{ .string = "tool" },      .{ .string = "FAIL one" },
        .{ .string = "s3" }, .{ .string = "assistant" }, .{ .string = "fail two" },
        .{ .string = "s4" }, .{ .string = "assistant" }, .{ .string = "fail three" },
    };
    var output: [4]Value = undefined;
    const result = try execute(
        program,
        .{ .values = &source, .width = 3 },
        &output,
    );
    try std.testing.expectEqual(@as(usize, 2), result.row_count);
    try std.testing.expectEqualStrings("s2", result.rows().row(0)[0].string);
    try std.testing.expectEqualStrings("FAIL one", result.rows().row(0)[1].string);
    try std.testing.expectEqualStrings("s3", result.rows().row(1)[0].string);
    try std.testing.expectEqualStrings("fail two", result.rows().row(1)[1].string);

    try expectStreamingFilterResult(program, &source, result);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileForAllocationFailure,
        .{
            &fixture.definition_plan,
            &fixture.native_plan,
            &fixture.bindings,
        },
    );
}

test "compiled numeric predicates bound nullable integer evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try compileTestProgram(
        &tmp.dir,
        numeric_filter_test_definition,
        &.{.{ .name = "through", .raw_value = "2" }},
        "rows",
    );
    defer fixture.deinit();
    const source = [_]Value{
        .{ .string = "before" },
        .{ .integer = 1 },
        .{ .string = "selected" },
        .{ .integer = 2 },
        .{ .string = "unassigned" },
        .null,
        .{ .string = "outcome" },
        .{ .integer = 3 },
    };
    var output: [4]Value = undefined;
    const result = try execute(
        &fixture.program,
        .{ .values = &source, .width = 2 },
        &output,
    );
    try std.testing.expectEqual(@as(usize, 2), result.row_count);
    try std.testing.expectEqualStrings(
        "before",
        result.rows().row(0)[0].string,
    );
    try std.testing.expectEqualStrings(
        "selected",
        result.rows().row(1)[0].string,
    );
}

test "ordered limits retain their position before later filters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try compileTestProgram(
        &tmp.dir,
        ordered_limit_test_definition,
        &.{},
        "rows",
    );
    defer fixture.deinit();
    try std.testing.expectEqualSlices(
        u16,
        &.{ 0, 1 },
        fixture.program.source_field_indices,
    );

    const source = [_]Value{
        .{ .string = "first" },  .{ .integer = 0 },
        .{ .string = "second" }, .{ .integer = 1 },
        .{ .string = "third" },  .{ .integer = 1 },
    };
    var output: [1]Value = undefined;
    const result = try execute(
        &fixture.program,
        .{ .values = &source, .width = 2 },
        &output,
    );
    try std.testing.expectEqual(@as(usize, 1), result.row_count);
    try std.testing.expectEqualStrings(
        "second",
        result.rows().row(0)[0].string,
    );
}

fn executeBlockingForAllocationFailure(
    allocator: std.mem.Allocator,
    program: *const Program,
    source: []const Value,
) !void {
    var output: [10]Value = undefined;
    _ = try executeAlloc(
        allocator,
        program,
        .{ .values = source, .width = 3 },
        &output,
    );
}

test "compiled sort and distinct preserve stable bounded semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try compileTestProgram(
        &tmp.dir,
        sort_distinct_test_definition,
        &.{},
        "rows",
    );
    defer fixture.deinit();
    const program = &fixture.program;

    try std.testing.expectEqual(@as(?u16, 0), program.first_blocking_operation);
    try std.testing.expectEqualSlices(
        u16,
        &.{ 0, 1, 2 },
        program.source_field_indices,
    );
    const source = [_]Value{
        .{ .string = "a" }, .{ .string = "x" }, .{ .integer = 2 },
        .{ .string = "b" }, .{ .string = "y" }, .null,
        .{ .string = "c" }, .{ .string = "x" }, .{ .integer = 3 },
        .{ .string = "d" }, .{ .string = "x" }, .{ .integer = 3 },
        .{ .string = "e" }, .{ .string = "z" }, .{ .integer = 1 },
    };
    var output: [10]Value = undefined;
    try std.testing.expectError(
        error.ObservationMaterializationWorkspaceRequired,
        execute(
            program,
            .{ .values = &source, .width = 3 },
            &output,
        ),
    );
    const result = try executeAlloc(
        std.testing.allocator,
        program,
        .{ .values = &source, .width = 3 },
        &output,
    );
    try std.testing.expectEqual(@as(usize, 5), result.source_row_count);
    try std.testing.expectEqual(@as(usize, 3), result.row_count);
    try std.testing.expectEqualStrings(
        "c",
        result.rows().row(0)[0].string,
    );
    try std.testing.expectEqual(@as(i64, 3), result.rows().row(0)[1].integer);
    try std.testing.expectEqualStrings(
        "e",
        result.rows().row(1)[0].string,
    );
    try std.testing.expectEqualStrings(
        "b",
        result.rows().row(2)[0].string,
    );
    try std.testing.expect(result.rows().row(2)[1] == .null);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        executeBlockingForAllocationFailure,
        .{ program, &source },
    );
}

test "compiled top-k binds its count once before execution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try compileTestProgram(
        &tmp.dir,
        top_k_test_definition,
        &.{.{ .name = "k", .raw_value = "2" }},
        "rows",
    );
    defer fixture.deinit();

    const source = [_]Value{
        .{ .string = "a" }, .{ .integer = 2 },
        .{ .string = "b" }, .{ .integer = 4 },
        .{ .string = "c" }, .{ .integer = 4 },
        .{ .string = "d" }, .{ .integer = 1 },
    };
    var output: [4]Value = undefined;
    const result = try executeAlloc(
        std.testing.allocator,
        &fixture.program,
        .{ .values = &source, .width = 2 },
        &output,
    );
    try std.testing.expectEqual(@as(usize, 2), result.row_count);
    try std.testing.expectEqualStrings(
        "b",
        result.rows().row(0)[0].string,
    );
    try std.testing.expectEqualStrings(
        "c",
        result.rows().row(1)[0].string,
    );
}

test "top-k retains only its bounded native working set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try compileTestProgram(
        &tmp.dir,
        top_k_test_definition,
        &.{.{ .name = "k", .raw_value = "2" }},
        "rows",
    );
    defer fixture.deinit();
    const source = [_]Value{
        .{ .string = "a" ** 128 }, .{ .integer = 2 },
        .{ .string = "b" ** 128 }, .{ .integer = 4 },
        .{ .string = "c" ** 128 }, .{ .integer = 4 },
        .{ .string = "d" ** 128 }, .{ .integer = 1 },
    };
    var output: [2]Value = undefined;
    var runner = try Runner.initOwnedAllocBounded(
        std.testing.allocator,
        &fixture.program,
        &output,
        256,
    );
    defer runner.deinit();
    for (0..4) |index| {
        const start = index * 2;
        _ = try runner.feed(source[start..][0..2]);
    }
    const result = try runner.finish();
    try std.testing.expectEqual(@as(usize, 2), result.row_count);
    try std.testing.expectEqual(@as(usize, 2), result.materialized_row_count);
    try std.testing.expectEqual(@as(usize, 256), runner.owned_value_bytes);
    try std.testing.expectEqualStrings(
        "b" ** 128,
        result.rows().row(0)[0].string,
    );
    try std.testing.expectEqualStrings(
        "c" ** 128,
        result.rows().row(1)[0].string,
    );
}

test "compiled aggregate streams bounded numeric summaries in one pass" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try compileTestProgram(
        &tmp.dir,
        aggregate_test_definition,
        &.{},
        "summary",
    );
    defer fixture.deinit();

    const source = [_]Value{
        .{ .integer = 5 }, .{ .float = 1.5 },
        .null,             .{ .float = 2.5 },
        .{ .integer = 7 }, .null,
    };
    var output: [7]Value = undefined;
    const result = try execute(
        &fixture.program,
        .{ .values = &source, .width = 2 },
        &output,
    );
    try std.testing.expectEqual(@as(usize, 1), result.row_count);
    try std.testing.expectEqual(@as(usize, 3), result.source_row_count);
    try std.testing.expectEqual(@as(usize, 0), result.materialized_row_count);
    const summary = result.rows().row(0);
    try std.testing.expectEqual(@as(i64, 3), summary[0].integer);
    try std.testing.expectEqual(@as(i64, 2), summary[1].integer);
    try std.testing.expectEqual(@as(i64, 12), summary[2].integer);
    try std.testing.expectEqual(@as(i64, 5), summary[3].integer);
    try std.testing.expectEqual(@as(i64, 7), summary[4].integer);
    try std.testing.expectApproxEqAbs(
        @as(f64, 6),
        summary[5].float,
        0.000001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 4),
        summary[6].float,
        0.000001,
    );

    var empty_output: [7]Value = undefined;
    var runner = try Runner.init(&fixture.program, &empty_output);
    defer runner.deinit();
    const empty = try runner.finish();
    const empty_summary = empty.rows().row(0);
    try std.testing.expectEqual(@as(i64, 0), empty_summary[0].integer);
    try std.testing.expectEqual(@as(i64, 0), empty_summary[1].integer);
    try std.testing.expectEqual(@as(i64, 0), empty_summary[2].integer);
    try std.testing.expect(empty_summary[3] == .null);
    try std.testing.expect(empty_summary[4] == .null);
    try std.testing.expect(empty_summary[5] == .null);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        empty_summary[6].float,
        0.000001,
    );
}

test "integer and float comparison preserves large integer identity" {
    const exact: i64 = 9_007_199_254_740_992;
    const adjacent: i64 = 9_007_199_254_740_993;
    const exact_float: f64 = 9_007_199_254_740_992.0;
    try std.testing.expect(valuesEqual(
        .{ .integer = exact },
        .{ .float = exact_float },
        false,
    ));
    try std.testing.expect(!valuesEqual(
        .{ .integer = adjacent },
        .{ .float = exact_float },
        false,
    ));
    try std.testing.expectEqual(
        std.math.Order.gt,
        compareValues(
            .{ .integer = adjacent },
            .{ .float = exact_float },
        ),
    );
    try std.testing.expectEqual(
        std.math.Order.lt,
        compareValues(
            .{ .float = exact_float },
            .{ .integer = adjacent },
        ),
    );
}

test "owned runners bound retained value bytes" {
    var source_fields = [_]u16{0};
    var output_fields = [_]u16{0};
    const program = Program{
        .source = .{ .physical = .messages },
        .source_width = 1,
        .source_field_indices = source_fields[0..],
        .materialized_field_indices = &.{},
        .source_row_bound = null,
        .operations = &.{},
        .predicates = &.{},
        .sort_keys = &.{},
        .distinct_fields = &.{},
        .aggregate_metrics = &.{},
        .output_field_indices = output_fields[0..],
        .limit_state_count = 0,
        .first_blocking_operation = null,
        .max_rows = 1,
    };
    var output: [1]Value = undefined;
    var runner = try Runner.initOwnedAllocBounded(
        std.testing.allocator,
        &program,
        &output,
        3,
    );
    defer runner.deinit();
    try std.testing.expectError(
        error.ObservationRetainedValueByteBoundExceeded,
        runner.feed(&.{.{ .string = "four" }}),
    );
}
