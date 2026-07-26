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

const RuntimePredicate = struct {
    field_index: u16,
    operator: plan.PredicateOperator,
    operand: Value,
    case_insensitive: bool,
};

const PredicateRange = struct {
    start: u16,
    len: u16,
};

const RuntimeSortKey = struct {
    field_index: u16,
    direction: plan.SortDirection,
    nulls: plan.NullOrder,
};

const FieldRange = struct {
    start: u16,
    len: u16,
};

const RuntimeOperation = union(enum) {
    filter: PredicateRange,
    limit: struct {
        count: usize,
        state_index: u16,
    },
    sort: FieldRange,
    distinct: FieldRange,
};

pub const Program = struct {
    source: Source,
    source_width: u16,
    source_field_indices: []u16,
    source_row_bound: ?usize,
    operations: []RuntimeOperation,
    predicates: []RuntimePredicate,
    sort_keys: []RuntimeSortKey,
    distinct_fields: []u16,
    output_field_indices: []u16,
    limit_state_count: u16,
    first_blocking_operation: ?u16,
    max_rows: usize,

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        allocator.free(self.source_field_indices);
        allocator.free(self.operations);
        allocator.free(self.predicates);
        allocator.free(self.sort_keys);
        allocator.free(self.distinct_fields);
        allocator.free(self.output_field_indices);
        self.* = undefined;
    }
};

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

    var stage_path: [256]u16 = undefined;
    var stage_count: usize = 0;
    var current_index = projection.stage_index;
    var source: Source = undefined;
    var source_width: usize = undefined;
    var physical_field_indices: ?[]const u16 = null;
    var source_row_bound: ?usize = null;
    while (true) {
        if (stage_count == stage_path.len) {
            return error.ObservationPipelineTooDeep;
        }
        stage_path[stage_count] = current_index;
        stage_count += 1;
        const stage = &native_plan.stages[current_index];
        if (stage.source) |stage_source| {
            switch (stage_source) {
                .stage => |index| {
                    current_index = index;
                    continue;
                },
                .external => |index| {
                    source = .{ .external = index };
                    source_width = definition_plan.inputs[index].fields.len;
                    source_row_bound = definition_plan.inputs[index].max_rows;
                    break;
                },
            }
        }
        const scan = switch (stage.operation) {
            .scan => |value| value,
            else => return error.ObservationPipelineSourceMissing,
        };
        source = .{ .physical = scan.relation };
        source_width = scan.field_indices.len;
        physical_field_indices = scan.field_indices;
        break;
    }

    if (source_width == 0 or source_width > 256) {
        return error.InvalidObservationSourceWidth;
    }
    var field_map: [256]u16 = undefined;
    for (field_map[0..source_width], 0..) |*field, index| {
        field.* = @intCast(index);
    }
    var field_count = source_width;
    const source_fields = try allocator.alloc(u16, source_width);
    errdefer allocator.free(source_fields);
    if (physical_field_indices) |indices| {
        @memcpy(source_fields, indices);
    } else {
        @memcpy(source_fields, field_map[0..source_width]);
    }

    var predicates: std.ArrayList(RuntimePredicate) = .empty;
    errdefer predicates.deinit(allocator);
    var operations: std.ArrayList(RuntimeOperation) = .empty;
    errdefer operations.deinit(allocator);
    var sort_keys: std.ArrayList(RuntimeSortKey) = .empty;
    errdefer sort_keys.deinit(allocator);
    var distinct_fields: std.ArrayList(u16) = .empty;
    errdefer distinct_fields.deinit(allocator);
    var limit_state_count: u16 = 0;
    var first_blocking_operation: ?u16 = null;

    var path_index = stage_count;
    while (path_index > 0) {
        path_index -= 1;
        const stage = &native_plan.stages[stage_path[path_index]];
        switch (stage.operation) {
            .scan, .alias => {},
            .filter => |filter| {
                const start = predicates.items.len;
                for (filter.predicates) |predicate| {
                    if (predicate.field_index >= field_count) {
                        return error.ObservationFieldIndexInvalid;
                    }
                    try predicates.append(allocator, .{
                        .field_index = field_map[predicate.field_index],
                        .operator = predicate.operator,
                        .operand = try resolveOperand(
                            definition_plan,
                            bindings,
                            predicate.operand,
                        ),
                        .case_insensitive = predicate.case_insensitive,
                    });
                }
                try operations.append(allocator, .{
                    .filter = .{
                        .start = @intCast(start),
                        .len = @intCast(predicates.items.len - start),
                    },
                });
            },
            .project => |project| {
                var projected: [256]u16 = undefined;
                if (project.input_field_indices.len > projected.len) {
                    return error.InvalidProjectionFieldCount;
                }
                for (project.input_field_indices, 0..) |field_index, index| {
                    if (field_index >= field_count) {
                        return error.ObservationFieldIndexInvalid;
                    }
                    projected[index] = field_map[field_index];
                }
                field_count = project.input_field_indices.len;
                @memcpy(field_map[0..field_count], projected[0..field_count]);
            },
            .limit => |limit| {
                if (limit_state_count == 256) {
                    return error.TooManyObservationLimits;
                }
                try operations.append(allocator, .{
                    .limit = .{
                        .count = try resolveLimit(
                            definition_plan,
                            bindings,
                            limit,
                            native_plan.max_rows,
                        ),
                        .state_index = limit_state_count,
                    },
                });
                limit_state_count += 1;
            },
            .sort => |sort| {
                if (first_blocking_operation == null) {
                    first_blocking_operation = @intCast(operations.items.len);
                }
                const start = sort_keys.items.len;
                for (sort.keys) |key| {
                    if (key.field_index >= field_count) {
                        return error.ObservationFieldIndexInvalid;
                    }
                    try sort_keys.append(allocator, .{
                        .field_index = field_map[key.field_index],
                        .direction = key.direction,
                        .nulls = key.nulls,
                    });
                }
                try operations.append(allocator, .{
                    .sort = .{
                        .start = @intCast(start),
                        .len = @intCast(sort_keys.items.len - start),
                    },
                });
            },
            .distinct => |distinct| {
                if (first_blocking_operation == null) {
                    first_blocking_operation = @intCast(operations.items.len);
                }
                const start = distinct_fields.items.len;
                for (distinct.field_indices) |field_index| {
                    if (field_index >= field_count) {
                        return error.ObservationFieldIndexInvalid;
                    }
                    try distinct_fields.append(
                        allocator,
                        field_map[field_index],
                    );
                }
                try operations.append(allocator, .{
                    .distinct = .{
                        .start = @intCast(start),
                        .len = @intCast(
                            distinct_fields.items.len - start,
                        ),
                    },
                });
            },
        }
    }

    const output_fields = try allocator.alloc(
        u16,
        projection.field_indices.len,
    );
    errdefer allocator.free(output_fields);
    for (projection.field_indices, 0..) |field_index, index| {
        if (field_index >= field_count) {
            return error.ObservationFieldIndexInvalid;
        }
        output_fields[index] = field_map[field_index];
    }
    const operation_slice = try operations.toOwnedSlice(allocator);
    errdefer allocator.free(operation_slice);
    const predicate_slice = try predicates.toOwnedSlice(allocator);
    errdefer allocator.free(predicate_slice);
    const sort_key_slice = try sort_keys.toOwnedSlice(allocator);
    errdefer allocator.free(sort_key_slice);
    const distinct_field_slice =
        try distinct_fields.toOwnedSlice(allocator);
    errdefer allocator.free(distinct_field_slice);

    return .{
        .source = source,
        .source_width = @intCast(source_width),
        .source_field_indices = source_fields,
        .source_row_bound = source_row_bound,
        .operations = operation_slice,
        .predicates = predicate_slice,
        .sort_keys = sort_key_slice,
        .distinct_fields = distinct_field_slice,
        .output_field_indices = output_fields,
        .limit_state_count = limit_state_count,
        .first_blocking_operation = first_blocking_operation,
        .max_rows = native_plan.max_rows,
    };
}

pub const Feed = enum {
    continue_scanning,
    stop,
};

const max_materialized_cells: usize = 4_000_000;

const RowRef = struct {
    row_index: usize,
    ordinal: usize,
};

pub const Runner = struct {
    program: *const Program,
    output: []Value,
    allocator: ?std.mem.Allocator = null,
    materialized: []Value = &.{},
    row_refs: []RowRef = &.{},
    auxiliary_refs: []RowRef = &.{},
    duplicate_marks: []bool = &.{},
    limit_states: [256]usize = undefined,
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
        const materialized_cells = std.math.mul(
            usize,
            program.max_rows,
            program.source_width,
        ) catch return error.ObservationMaterializationCellBoundExceeded;
        if (materialized_cells > max_materialized_cells) {
            return error.ObservationMaterializationCellBoundExceeded;
        }
        const materialized = try allocator.alloc(
            Value,
            materialized_cells,
        );
        errdefer allocator.free(materialized);
        const row_refs = try allocator.alloc(RowRef, program.max_rows);
        errdefer allocator.free(row_refs);
        const auxiliary_refs = try allocator.alloc(
            RowRef,
            program.max_rows,
        );
        errdefer allocator.free(auxiliary_refs);
        const duplicate_marks = try allocator.alloc(
            bool,
            program.max_rows,
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
        return runner;
    }

    pub fn deinit(self: *Runner) void {
        if (self.allocator) |allocator| {
            allocator.free(self.materialized);
            allocator.free(self.row_refs);
            allocator.free(self.auxiliary_refs);
            allocator.free(self.duplicate_marks);
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
            if (self.program.first_blocking_operation != null) {
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
                ref.* = .{ .row_index = index, .ordinal = index };
            }
            for (self.program.operations[start..]) |operation| {
                active_count = switch (operation) {
                    .filter => |range| self.filterRows(
                        active_count,
                        range,
                    ),
                    .limit => |limit| @min(active_count, limit.count),
                    .sort => |range| self.sortRows(active_count, range),
                    .distinct => |range| self.distinctRows(
                        active_count,
                        range,
                    ),
                };
                resetOrdinals(self.row_refs[0..active_count]);
            }
            for (self.row_refs[0..active_count]) |ref| {
                try self.append(self.materializedRow(ref.row_index));
            }
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
                .filter => |range| {
                    if (!self.rowMatches(row, range)) {
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
                .sort, .distinct => {
                    return error.ObservationBlockingOperatorInStreamingPrefix;
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
    ) bool {
        const end = @as(usize, range.start) + range.len;
        for (self.program.predicates[range.start..end]) |predicate| {
            if (!matches(row[predicate.field_index], predicate)) return false;
        }
        return true;
    }

    fn materialize(self: *Runner, row: []const Value) !void {
        if (self.materialized_row_count == self.program.max_rows) {
            return error.ObservationMaterializationRowBoundExceeded;
        }
        const start = self.materialized_row_count * self.program.source_width;
        @memcpy(
            self.materialized[start..][0..self.program.source_width],
            row,
        );
        self.materialized_row_count += 1;
    }

    fn materializedRow(
        self: *const Runner,
        row_index: usize,
    ) []const Value {
        const start = row_index * self.program.source_width;
        return self.materialized[start..][0..self.program.source_width];
    }

    fn filterRows(
        self: *Runner,
        active_count: usize,
        range: PredicateRange,
    ) usize {
        var output_index: usize = 0;
        for (self.row_refs[0..active_count]) |ref| {
            if (!self.rowMatches(
                self.materializedRow(ref.row_index),
                range,
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
            self.output[output_start + index] = row[field_index];
        }
        self.output_row_count += 1;
    }
};

fn validateRunnerInputs(program: *const Program) !void {
    if (program.source_width == 0) {
        return error.InvalidObservationSourceWidth;
    }
    if (program.output_field_indices.len == 0) {
        return error.InvalidObservationOutputWidth;
    }
}

fn resetOrdinals(refs: []RowRef) void {
    for (refs, 0..) |*ref, index| ref.ordinal = index;
}

const SortContext = struct {
    runner: *const Runner,
    keys: []const RuntimeSortKey,

    fn lessThan(context: SortContext, left: RowRef, right: RowRef) bool {
        const left_row = context.runner.materializedRow(left.row_index);
        const right_row = context.runner.materializedRow(right.row_index);
        for (context.keys) |key| {
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
        return left.ordinal < right.ordinal;
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
            .float => |right_number| compareFloat(
                @floatFromInt(left_number),
                right_number,
            ),
            else => compareValueTags(left, right),
        },
        .float => |left_number| switch (right) {
            .integer => |right_number| compareFloat(
                left_number,
                @floatFromInt(right_number),
            ),
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
    };
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
            .float => |right_number| @as(f64, @floatFromInt(left_number)) ==
                right_number,
            else => false,
        },
        .float => |left_number| switch (right) {
            .integer => |right_number| left_number ==
                @as(f64, @floatFromInt(right_number)),
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

test "compiled execution filters projects and limits without intermediate rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/messages","requires":{"abi":"seq-observation-abi/v1","operators":["scan","filter","project","limit"]},"parameters":{"needle":{"type":"string","required":true}},"selectors":["path"],"relations":[{"name":"messages","fields":["session_id","role","text"]}],"inputs":[],"pipeline":[{"op":"scan","relation":"messages","as":"source"},{"op":"filter","input":"source","as":"matched","where":[{"field":"text","op":"contains","param":"needle","case_insensitive":true}]},{"op":"project","input":"matched","as":"rows","fields":["session_id","text"]},{"op":"limit","input":"rows","as":"bounded","limit":2}],"projections":{"rows":{"relation":"bounded","schema":"example-message-rows/v1","fields":["session_id","text"],"renderers":["json"]}},"bounds":{"max_rows":100,"max_output_bytes":4096,"max_fold_states":8}}
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
    var native_plan = try plan.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer native_plan.deinit(std.testing.allocator);
    var bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "needle", .raw_value = "FAIL" }},
    );
    defer bindings.deinit(std.testing.allocator);
    var program = try compile(
        std.testing.allocator,
        &definition_plan,
        &native_plan,
        &bindings,
        "rows",
    );
    defer program.deinit(std.testing.allocator);
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
        &program,
        .{ .values = &source, .width = 3 },
        &output,
    );
    try std.testing.expectEqual(@as(usize, 2), result.row_count);
    try std.testing.expectEqualStrings("s2", result.rows().row(0)[0].string);
    try std.testing.expectEqualStrings("FAIL one", result.rows().row(0)[1].string);
    try std.testing.expectEqualStrings("s3", result.rows().row(1)[0].string);
    try std.testing.expectEqualStrings("fail two", result.rows().row(1)[1].string);

    var streamed_output: [4]Value = undefined;
    var runner = try Runner.init(&program, &streamed_output);
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
    try std.testing.expectEqual(result.row_count, streamed.row_count);
    try std.testing.expectEqualStrings(
        result.rows().row(0)[0].string,
        streamed.rows().row(0)[0].string,
    );
    try std.testing.expectEqualStrings(
        result.rows().row(1)[1].string,
        streamed.rows().row(1)[1].string,
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileForAllocationFailure,
        .{ &definition_plan, &native_plan, &bindings },
    );
}

test "ordered limits retain their position before later filters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/ordered","requires":{"abi":"seq-observation-abi/v1","operators":["limit","filter","project"]},"parameters":{},"selectors":[],"relations":[],"inputs":[{"name":"facts","schema":"example-facts/v1","fields":[{"name":"id","type":"string","nullable":false},{"name":"score","type":"integer","nullable":false}],"max_rows":3,"max_bytes":4096}],"pipeline":[{"op":"limit","input":"facts","as":"first","limit":2},{"op":"filter","input":"first","as":"matched","where":[{"field":"score","op":"exact","value":1}]},{"op":"project","input":"matched","as":"rows","fields":["id"]}],"projections":{"rows":{"relation":"rows","schema":"example-rows/v1","fields":["id"],"renderers":["json"]}},"bounds":{"max_rows":3,"max_output_bytes":4096,"max_fold_states":2}}
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
    var native_plan = try plan.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer native_plan.deinit(std.testing.allocator);
    var bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{},
    );
    defer bindings.deinit(std.testing.allocator);
    var program = try compile(
        std.testing.allocator,
        &definition_plan,
        &native_plan,
        &bindings,
        "rows",
    );
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u16,
        &.{ 0, 1 },
        program.source_field_indices,
    );

    const source = [_]Value{
        .{ .string = "first" },  .{ .integer = 0 },
        .{ .string = "second" }, .{ .integer = 1 },
        .{ .string = "third" },  .{ .integer = 1 },
    };
    var output: [1]Value = undefined;
    const result = try execute(
        &program,
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
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/ranked-distinct","requires":{"abi":"seq-observation-abi/v1","operators":["sort","distinct","limit","project"]},"parameters":{},"selectors":[],"relations":[],"inputs":[{"name":"facts","schema":"example-facts/v1","fields":[{"name":"id","type":"string","nullable":false},{"name":"group","type":"string","nullable":false},{"name":"score","type":"integer","nullable":true}],"max_rows":5,"max_bytes":4096}],"pipeline":[{"op":"sort","input":"facts","as":"ranked","by":[{"field":"score","direction":"desc","nulls":"last"}]},{"op":"distinct","input":"ranked","as":"unique","keys":["group"]},{"op":"limit","input":"unique","as":"bounded","limit":3},{"op":"project","input":"bounded","as":"rows","fields":["id","score"]}],"projections":{"rows":{"relation":"rows","schema":"example-ranked/v1","fields":["id","score"],"renderers":["json"]}},"bounds":{"max_rows":5,"max_output_bytes":4096,"max_fold_states":2}}
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
    var native_plan = try plan.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer native_plan.deinit(std.testing.allocator);
    var bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{},
    );
    defer bindings.deinit(std.testing.allocator);
    var program = try compile(
        std.testing.allocator,
        &definition_plan,
        &native_plan,
        &bindings,
        "rows",
    );
    defer program.deinit(std.testing.allocator);

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
            &program,
            .{ .values = &source, .width = 3 },
            &output,
        ),
    );
    const result = try executeAlloc(
        std.testing.allocator,
        &program,
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
        .{ &program, &source },
    );
}
