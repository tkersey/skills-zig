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

const RuntimeOperation = union(enum) {
    filter: PredicateRange,
    limit: struct {
        count: usize,
        state_index: u16,
    },
};

pub const Program = struct {
    source: Source,
    source_width: u16,
    source_row_bound: ?usize,
    operations: []RuntimeOperation,
    predicates: []RuntimePredicate,
    output_field_indices: []u16,
    limit_state_count: u16,
    max_rows: usize,

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        allocator.free(self.operations);
        allocator.free(self.predicates);
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

    var predicates: std.ArrayList(RuntimePredicate) = .empty;
    errdefer predicates.deinit(allocator);
    var operations: std.ArrayList(RuntimeOperation) = .empty;
    errdefer operations.deinit(allocator);
    var limit_state_count: u16 = 0;

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

    return .{
        .source = source,
        .source_width = @intCast(source_width),
        .source_row_bound = source_row_bound,
        .operations = operation_slice,
        .predicates = predicate_slice,
        .output_field_indices = output_fields,
        .limit_state_count = limit_state_count,
        .max_rows = native_plan.max_rows,
    };
}

pub fn execute(
    program: *const Program,
    source_rows: Rows,
    output: []Value,
) !Result {
    if (source_rows.width != program.source_width) {
        return error.ObservationSourceWidthMismatch;
    }
    const source_row_count = try source_rows.count();
    if (program.source_row_bound) |bound| {
        if (source_row_count > bound) {
            return error.ObservationSourceRowBoundExceeded;
        }
    }
    const output_width = program.output_field_indices.len;
    if (output_width == 0) return error.InvalidObservationOutputWidth;

    var limit_states: [256]usize = undefined;
    @memset(limit_states[0..program.limit_state_count], 0);
    var output_row_count: usize = 0;
    for (0..source_row_count) |row_index| {
        const row = source_rows.row(row_index);
        var accepted = true;
        var stop_after_row = false;
        for (program.operations) |operation| {
            switch (operation) {
                .filter => |range| {
                    const end = @as(usize, range.start) + range.len;
                    for (program.predicates[range.start..end]) |predicate| {
                        if (!matches(row[predicate.field_index], predicate)) {
                            accepted = false;
                            break;
                        }
                    }
                    if (!accepted) break;
                },
                .limit => |limit| {
                    if (limit_states[limit.state_index] == limit.count) {
                        return .{
                            .values = output,
                            .width = output_width,
                            .row_count = output_row_count,
                        };
                    }
                    limit_states[limit.state_index] += 1;
                    stop_after_row = stop_after_row or
                        limit_states[limit.state_index] == limit.count;
                },
            }
        }
        if (accepted) {
            if (output_row_count == program.max_rows) {
                return error.ObservationRowBoundExceeded;
            }
            const output_start = std.math.mul(
                usize,
                output_row_count,
                output_width,
            ) catch return error.ObservationOutputSizeOverflow;
            const output_end = std.math.add(
                usize,
                output_start,
                output_width,
            ) catch return error.ObservationOutputSizeOverflow;
            if (output_end > output.len) {
                return error.ObservationOutputBufferTooSmall;
            }
            for (program.output_field_indices, 0..) |field_index, index| {
                output[output_start + index] = row[field_index];
            }
            output_row_count += 1;
        }
        if (stop_after_row) break;
    }
    return .{
        .values = output,
        .width = output_width,
        .row_count = output_row_count,
    };
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
