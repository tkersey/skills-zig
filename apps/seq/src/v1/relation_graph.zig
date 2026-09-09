const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const execution = @import("execution.zig");
const plan = @import("plan.zig");
const seq_time = @import("seq_time");

pub const RuntimeSelectors = struct {
    path: ?[]const u8 = null,
    root: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
};

pub const Table = struct {
    values: []execution.Value,
    width: usize,

    pub fn rowCount(self: Table) !usize {
        if (self.width == 0 or self.values.len % self.width != 0) {
            return error.InvalidObservationRows;
        }
        return self.values.len / self.width;
    }

    pub fn row(self: Table, index: usize) []const execution.Value {
        return self.values[index * self.width ..][0..self.width];
    }
};

pub const ScanInput = struct {
    stage_index: u16,
    table: Table,
    allocation: ?[]execution.Value = null,
    owned: bool = false,
};

pub const Result = struct {
    table: Table,
    source_rows: usize,
    materialized_rows: usize,
};

pub const TargetResult = struct {
    table: Table,
    source_rows: usize,
    materialized_rows: usize,
};

pub const StreamingLineagePlan = struct {
    scan_stage: u16,
    local_stage: u16,
    lineage_stage: u16,
    graph_stage: u16,
};

pub fn streamingLineagePlan(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    projection_name: []const u8,
) !?StreamingLineagePlan {
    const projection_index = findProjection(definition_plan, projection_name) orelse
        return error.UnknownObservationProjection;
    const reachable = try allocator.alloc(bool, native_plan.stages.len);
    defer allocator.free(reachable);
    @memset(reachable, false);
    try markReachable(
        allocator,
        definition_plan,
        native_plan,
        native_plan.projections[projection_index].stage_index,
        reachable,
        &.{},
        0,
    );
    for (native_plan.stages, 0..) |stage, stage_index| {
        if (!reachable[stage_index] or stage.operation != .generic) continue;
        const generic = stage.operation.generic;
        if (generic.operator != .join) continue;
        var parsed = try parseConfig(allocator, generic.canonical_config);
        defer parsed.deinit();
        const root = try definition_core.json.object(parsed.value);
        const on = try definition_core.json.object(
            try definition_core.json.field(root, "on"),
        );
        if (on.get("lineage") == null) continue;
        const step = definition_plan.steps[stage_index];
        if (step.input_names.len != 3 or
            !std.mem.eql(u8, step.input_names[0], step.input_names[1]))
        {
            return error.ObservationStreamingLineageShapeUnsupported;
        }
        const local_stage = native_plan.findStage(step.input_names[0]) orelse
            return error.ObservationExternalGraphInputUnsupported;
        const graph_stage = native_plan.findStage(step.input_names[2]) orelse
            return error.ObservationExternalGraphInputUnsupported;
        const scan_stage = try partitionScanRoot(
            allocator,
            definition_plan,
            native_plan,
            local_stage,
            null,
            0,
        );
        return .{
            .scan_stage = scan_stage,
            .local_stage = local_stage,
            .lineage_stage = @intCast(stage_index),
            .graph_stage = graph_stage,
        };
    }
    return null;
}

const StageFrame = struct {
    stage_index: u16,
    next_input: usize = 0,
    entered: bool = false,
};

fn partitionScanRoot(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    stage_index: u16,
    expected: ?u16,
    depth: usize,
) !u16 {
    const max_depth = definition_plan.bounds.max_graph_depth;
    if (depth > max_depth) return error.ObservationGraphDepthExceeded;
    const frames = try allocator.alloc(StageFrame, max_depth - depth + 1);
    defer allocator.free(frames);
    frames[0] = .{ .stage_index = stage_index };
    var count: usize = 1;
    var root = expected;
    while (count > 0) {
        const frame = &frames[count - 1];
        const stage = native_plan.stages[frame.stage_index];
        if (!frame.entered) {
            frame.entered = true;
            if (stage.operation == .scan) {
                try validatePartitionScan(stage, frame.stage_index, root);
                root = frame.stage_index;
                count -= 1;
                continue;
            }
            try validatePartitionOperator(stage);
        }
        const step = definition_plan.steps[frame.stage_index];
        if (step.input_names.len == 0) return error.ObservationPartitionLayoutMissing;
        if (frame.next_input == step.input_names.len) {
            count -= 1;
            continue;
        }
        const name = step.input_names[frame.next_input];
        frame.next_input += 1;
        const input = native_plan.findStage(name) orelse
            return error.ObservationExternalGraphInputUnsupported;
        if (count == frames.len) return error.ObservationGraphDepthExceeded;
        frames[count] = .{ .stage_index = input };
        count += 1;
    }
    return root.?;
}

fn validatePartitionScan(stage: plan.Stage, stage_index: u16, expected: ?u16) !void {
    if (stage.operation.scan.relation.layout().partition_field == null) {
        return error.ObservationPartitionLayoutMissing;
    }
    if (expected) |wanted| if (wanted != stage_index) {
        return error.ObservationPartitionPrefixHasMultipleScans;
    };
}

fn validatePartitionOperator(stage: plan.Stage) !void {
    switch (stage.operation) {
        .filter, .project, .alias, .distinct => {},
        .generic => |generic| switch (generic.operator) {
            .derive, .ordered_fold, .join => {},
            else => return error.ObservationPartitionOperatorUnsupported,
        },
        else => return error.ObservationPartitionOperatorUnsupported,
    }
}

pub fn requiredScanStages(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    projection_name: []const u8,
) ![]u16 {
    const projection_index = findProjection(definition_plan, projection_name) orelse
        return error.UnknownObservationProjection;
    const reachable = try allocator.alloc(bool, native_plan.stages.len);
    defer allocator.free(reachable);
    @memset(reachable, false);
    try markReachable(
        allocator,
        definition_plan,
        native_plan,
        native_plan.projections[projection_index].stage_index,
        reachable,
        &.{},
        0,
    );
    var scans: std.ArrayList(u16) = .empty;
    errdefer scans.deinit(allocator);
    for (native_plan.stages, 0..) |stage, index| {
        if (reachable[index] and stage.operation == .scan) {
            try scans.append(allocator, @intCast(index));
        }
    }
    return scans.toOwnedSlice(allocator);
}

const GraphExecution = struct {
    allocator: std.mem.Allocator,
    retained_allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
    scans: []ScanInput,
    reachable: []bool,
    tables: []?Table,
    owned: []bool,
    allocations: []?[]execution.Value,
    consumers: []usize,
    source_rows: usize = 0,
    materialized_rows: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        retained_allocator: std.mem.Allocator,
        definition_plan: *const definition.Plan,
        native_plan: *const plan.Plan,
        bindings: *const definition_core.parameters.Bindings,
        selectors: RuntimeSelectors,
        scans: []ScanInput,
        target: u16,
    ) !GraphExecution {
        const count = native_plan.stages.len;
        const reachable = try allocator.alloc(bool, count);
        errdefer allocator.free(reachable);
        @memset(reachable, false);
        try markReachable(allocator, definition_plan, native_plan, target, reachable, scans, 0);
        const tables = try allocator.alloc(?Table, count);
        errdefer allocator.free(tables);
        @memset(tables, null);
        const owned = try allocator.alloc(bool, count);
        errdefer allocator.free(owned);
        @memset(owned, false);
        const allocations = try allocator.alloc(?[]execution.Value, count);
        errdefer allocator.free(allocations);
        @memset(allocations, null);
        const consumers = try allocator.alloc(usize, count);
        errdefer allocator.free(consumers);
        @memset(consumers, 0);
        var result: GraphExecution = .{
            .allocator = allocator,
            .retained_allocator = retained_allocator,
            .definition_plan = definition_plan,
            .native_plan = native_plan,
            .bindings = bindings,
            .selectors = selectors,
            .scans = scans,
            .reachable = reachable,
            .tables = tables,
            .owned = owned,
            .allocations = allocations,
            .consumers = consumers,
        };
        try result.countConsumers(target);
        return result;
    }

    fn countConsumers(self: *GraphExecution, target: u16) !void {
        for (self.definition_plan.steps, 0..) |step, index| {
            if (!self.reachable[index] or findScan(self.scans, @intCast(index)) != null) continue;
            for (step.input_names) |name| {
                const input = self.native_plan.findStage(name) orelse continue;
                self.consumers[input] = try std.math.add(usize, self.consumers[input], 1);
            }
        }
        self.consumers[target] = try std.math.add(usize, self.consumers[target], 1);
    }

    fn deinit(self: *GraphExecution) void {
        for (self.tables, self.owned, 0..) |table, owned, index| {
            if (owned and table != null) self.release(index);
        }
        self.allocator.free(self.consumers);
        self.allocator.free(self.allocations);
        self.allocator.free(self.owned);
        self.allocator.free(self.tables);
        self.allocator.free(self.reachable);
    }

    fn release(self: *GraphExecution, index: usize) void {
        releaseStage(
            self.allocator,
            self.tables,
            self.owned,
            self.allocations,
            index,
            self.scans,
        );
    }

    fn run(self: *GraphExecution, target: u16) !Table {
        for (self.native_plan.stages, 0..) |_, index| {
            if (self.reachable[index]) try self.runStage(@intCast(index));
        }
        return self.tables[target] orelse error.ObservationProjectionNotExecuted;
    }

    fn runStage(self: *GraphExecution, index: u16) !void {
        const step = self.definition_plan.steps[index];
        const scan = findScan(self.scans, index);
        const table = if (scan) |found| blk: {
            self.source_rows = try std.math.add(
                usize,
                self.source_rows,
                try found.table.rowCount(),
            );
            self.owned[index] = found.owned;
            self.allocations[index] = found.allocation orelse found.table.values;
            break :blk found.table;
        } else blk: {
            const value = try executeStage(
                self.allocator,
                self.retained_allocator,
                self.definition_plan,
                self.native_plan,
                self.bindings,
                self.selectors,
                self.native_plan.stages[index],
                step,
                self.tables,
            );
            self.adoptTable(index, step, value);
            break :blk value;
        };
        // Record the owner before any subsequent fallible validation.
        self.tables[index] = table;
        const count = try table.rowCount();
        if (count > self.definition_plan.bounds.max_rows) return error.ObservationRowBoundExceeded;
        self.materialized_rows = try std.math.add(usize, self.materialized_rows, count);
        if (scan == null) self.consumeInputs(step);
    }

    fn adoptTable(self: *GraphExecution, index: u16, step: definition.Step, table: Table) void {
        self.owned[index] = true;
        self.allocations[index] = table.values;
        for (step.input_names) |name| {
            const input = self.native_plan.findStage(name) orelse continue;
            const prior = self.tables[input] orelse continue;
            if (table.values.ptr != prior.values.ptr) continue;
            self.owned[index] = self.owned[input];
            self.owned[input] = false;
            self.allocations[index] = self.allocations[input];
            self.allocations[input] = null;
            if (findScan(self.scans, input)) |scan| scan.owned = false;
            break;
        }
    }

    fn consumeInputs(self: *GraphExecution, step: definition.Step) void {
        for (step.input_names) |name| {
            const input = self.native_plan.findStage(name) orelse continue;
            std.debug.assert(self.consumers[input] > 0);
            self.consumers[input] -= 1;
            if (self.consumers[input] == 0 and self.owned[input]) self.release(input);
        }
    }
};

pub fn execute(
    allocator: std.mem.Allocator,
    retained_allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
    projection_name: []const u8,
    scans: []ScanInput,
) !Result {
    const projection_index = findProjection(definition_plan, projection_name) orelse
        return error.UnknownObservationProjection;
    const projection = native_plan.projections[projection_index];
    var graph = try GraphExecution.init(
        allocator,
        retained_allocator,
        definition_plan,
        native_plan,
        bindings,
        selectors,
        scans,
        projection.stage_index,
    );
    defer graph.deinit();
    const projected = try graph.run(projection.stage_index);
    const rows = try projected.rowCount();
    const output = try allocator.alloc(
        execution.Value,
        try std.math.mul(usize, rows, projection.field_indices.len),
    );
    for (0..rows) |row_index| {
        const row = projected.row(row_index);
        for (projection.field_indices, 0..) |field, field_index| {
            output[row_index * projection.field_indices.len + field_index] = row[field];
        }
    }
    return .{
        .table = .{ .values = output, .width = projection.field_indices.len },
        .source_rows = graph.source_rows,
        .materialized_rows = graph.materialized_rows,
    };
}

pub fn executeTarget(
    allocator: std.mem.Allocator,
    retained_allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
    target_stage: u16,
    scans: []ScanInput,
) !TargetResult {
    var graph = try GraphExecution.init(
        allocator,
        retained_allocator,
        definition_plan,
        native_plan,
        bindings,
        selectors,
        scans,
        target_stage,
    );
    defer graph.deinit();
    const target = try graph.run(target_stage);
    const output = try allocator.dupe(execution.Value, target.values);
    return .{
        .table = .{ .values = output, .width = target.width },
        .source_rows = graph.source_rows,
        .materialized_rows = graph.materialized_rows,
    };
}

fn markReachable(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    stage_index: u16,
    reachable: []bool,
    scans: []ScanInput,
    depth: usize,
) !void {
    const max_depth = definition_plan.bounds.max_graph_depth;
    if (depth > max_depth) return error.ObservationGraphDepthExceeded;
    const frames = try allocator.alloc(StageFrame, max_depth - depth + 1);
    defer allocator.free(frames);
    frames[0] = .{ .stage_index = stage_index };
    var count: usize = 1;
    while (count > 0) {
        const frame = &frames[count - 1];
        if (!frame.entered) {
            frame.entered = true;
            if (reachable[frame.stage_index]) {
                count -= 1;
                continue;
            }
            reachable[frame.stage_index] = true;
            if (findScan(scans, frame.stage_index) != null) {
                count -= 1;
                continue;
            }
        }
        const step = definition_plan.steps[frame.stage_index];
        if (frame.next_input == step.input_names.len) {
            count -= 1;
            continue;
        }
        const name = step.input_names[frame.next_input];
        frame.next_input += 1;
        const input = native_plan.findStage(name) orelse continue;
        if (count == frames.len) return error.ObservationGraphDepthExceeded;
        frames[count] = .{ .stage_index = input };
        count += 1;
    }
}

fn findProjection(
    definition_plan: *const definition.Plan,
    name: []const u8,
) ?u16 {
    for (definition_plan.projections, 0..) |projection, index| {
        if (std.mem.eql(u8, projection.name, name)) return @intCast(index);
    }
    return null;
}

fn findScan(scans: []ScanInput, stage_index: u16) ?*ScanInput {
    for (scans) |*scan| if (scan.stage_index == stage_index) return scan;
    return null;
}

fn releaseStage(
    allocator: std.mem.Allocator,
    tables: []?Table,
    owned: []bool,
    allocations: []?[]execution.Value,
    stage_index: usize,
    scans: []ScanInput,
) void {
    allocator.free(allocations[stage_index].?);
    tables[stage_index] = null;
    owned[stage_index] = false;
    allocations[stage_index] = null;
    if (findScan(scans, @intCast(stage_index))) |scan| {
        scan.table.values = &.{};
        scan.allocation = null;
        scan.owned = false;
    }
}

fn executeStage(
    allocator: std.mem.Allocator,
    retained_allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
    stage: plan.Stage,
    step: definition.Step,
    tables: []const ?Table,
) !Table {
    const first_index = native_plan.findStage(step.input_names[0]) orelse
        return error.ObservationExternalGraphInputUnsupported;
    const input = tables[first_index] orelse return error.ObservationInputNotExecuted;
    return switch (stage.operation) {
        .filter => |filter| try filterTable(
            allocator,
            definition_plan,
            bindings,
            input,
            filter,
        ),
        .project => |project| try projectTable(allocator, input, project),
        .limit => |limit| try limitTable(
            allocator,
            definition_plan,
            bindings,
            input,
            limit,
        ),
        .sort => |sort| try sortTable(allocator, input, sort),
        .top_k => |top_k| try topKTable(allocator, definition_plan, bindings, input, top_k),
        .distinct => |distinct| try distinctTable(
            allocator,
            input,
            distinct,
        ),
        .alias => try copyTable(allocator, input),
        .generic => try executeGenericStage(
            allocator,
            retained_allocator,
            definition_plan,
            native_plan,
            bindings,
            selectors,
            stage,
            step,
            tables,
            input,
            first_index,
        ),
        .aggregate => |aggregate| try aggregateTable(
            allocator,
            input,
            aggregate,
            stage.schema,
        ),
        .scan => error.ObservationOperatorPlanNotCompiled,
    };
}

fn topKTable(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    bindings: *const definition_core.parameters.Bindings,
    input: Table,
    top_k: plan.TopK,
) !Table {
    const sorted = try sortTable(allocator, input, .{ .keys = top_k.keys });
    defer allocator.free(sorted.values);
    return limitTable(allocator, definition_plan, bindings, sorted, top_k.limit);
}

fn executeGenericStage(
    allocator: std.mem.Allocator,
    retained_allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
    stage: plan.Stage,
    step: definition.Step,
    tables: []const ?Table,
    input: Table,
    first_index: u16,
) !Table {
    const generic = stage.operation.generic;
    return switch (generic.operator) {
        .derive => try deriveTable(
            allocator,
            retained_allocator,
            bindings,
            selectors,
            input,
            &native_plan.stages[first_index].schema,
            stage.schema,
            generic.canonical_config,
        ),
        .join => try joinTable(
            allocator,
            native_plan,
            step,
            tables,
            stage.schema,
            generic.canonical_config,
            definition_plan.bounds,
        ),
        .ordered_fold => try orderedFoldTable(
            allocator,
            retained_allocator,
            bindings,
            selectors,
            input,
            &native_plan.stages[first_index].schema,
            stage.schema,
            generic.canonical_config,
            definition_plan.bounds.max_fold_states,
        ),
        .reachability => try reachabilityTable(
            allocator,
            input,
            &native_plan.stages[first_index].schema,
            stage.schema,
            generic.canonical_config,
            definition_plan.bounds,
        ),
        else => error.ObservationOperatorPlanNotCompiled,
    };
}

fn copyTable(allocator: std.mem.Allocator, input: Table) !Table {
    return .{
        .values = try allocator.dupe(execution.Value, input.values),
        .width = input.width,
    };
}

fn projectTable(
    allocator: std.mem.Allocator,
    input: Table,
    project: plan.Project,
) !Table {
    const count = try input.rowCount();
    const values = try allocator.alloc(
        execution.Value,
        count * project.input_field_indices.len,
    );
    for (0..count) |row_index| {
        const row = input.row(row_index);
        for (project.input_field_indices, 0..) |field, index| {
            values[row_index * project.input_field_indices.len + index] =
                row[field];
        }
    }
    return .{ .values = values, .width = project.input_field_indices.len };
}

fn filterTable(
    _: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    bindings: *const definition_core.parameters.Bindings,
    input: Table,
    filter: plan.Filter,
) !Table {
    var accepted_count: usize = 0;
    for (0..try input.rowCount()) |row_index| {
        const row = input.row(row_index);
        var matches_count: usize = 0;
        for (filter.predicates) |predicate| {
            const operand = try resolveOperand(
                bindings,
                definition_plan,
                predicate.operand,
            );
            if (valueMatches(
                row[predicate.field_index],
                operand,
                predicate.operator,
                predicate.case_insensitive,
            )) matches_count += 1;
        }
        const accepted = switch (filter.mode) {
            .all => matches_count == filter.predicates.len,
            .any => matches_count != 0,
        };
        if (accepted) {
            if (accepted_count != row_index) {
                @memcpy(
                    input.values[accepted_count * input.width ..][0..input.width],
                    row,
                );
            }
            accepted_count += 1;
        }
    }
    return .{
        .values = input.values[0 .. accepted_count * input.width],
        .width = input.width,
    };
}

const AggregateState = struct {
    count: usize = 0,
    integer: i64 = 0,
    float: f64 = 0,
    seen: bool = false,
};

fn aggregateTable(
    allocator: std.mem.Allocator,
    input: Table,
    aggregate: plan.Aggregate,
    output_schema: plan.Schema,
) !Table {
    const states = try allocator.alloc(AggregateState, aggregate.metrics.len);
    defer allocator.free(states);
    @memset(states, .{});
    for (0..try input.rowCount()) |row_index| {
        const row = input.row(row_index);
        for (aggregate.metrics, 0..) |metric, metric_index| {
            const state = &states[metric_index];
            if (metric.function == .count and metric.field_index == null) {
                state.count = try std.math.add(usize, state.count, 1);
                continue;
            }
            const value = row[metric.field_index.?];
            if (value == .null) continue;
            state.count = try std.math.add(usize, state.count, 1);
            try accumulateMetric(state, metric, value);
            state.seen = true;
            if (!std.math.isFinite(state.float)) return error.ObservationAggregateOverflow;
        }
    }
    const values = try allocator.alloc(execution.Value, aggregate.metrics.len);
    for (aggregate.metrics, 0..) |metric, index| {
        const state = states[index];
        const kind = output_schema.columns[index].kind;
        values[index] = switch (metric.function) {
            .count => .{ .integer = @intCast(state.count) },
            .sum => if (kind == .integer)
                .{ .integer = state.integer }
            else
                .{ .float = state.float },
            .average => if (state.count == 0)
                .null
            else
                .{ .float = state.float / @as(f64, @floatFromInt(state.count)) },
            .min, .max => if (!state.seen)
                .null
            else if (kind == .integer)
                .{ .integer = state.integer }
            else
                .{ .float = state.float },
        };
    }
    return .{ .values = values, .width = values.len };
}

fn accumulateMetric(
    state: *AggregateState,
    metric: plan.AggregateMetric,
    value: execution.Value,
) !void {
    switch (metric.function) {
        .count => {},
        .sum, .average => switch (value) {
            .integer => |number| {
                state.integer = std.math.add(i64, state.integer, number) catch
                    return error.ObservationAggregateOverflow;
                state.float += @floatFromInt(number);
            },
            .float => |number| state.float += number,
            else => return error.ObservationAggregateTypeMismatch,
        },
        .min, .max => switch (value) {
            .integer => |number| {
                if (!state.seen or
                    (metric.function == .min and number < state.integer) or
                    (metric.function == .max and number > state.integer))
                {
                    state.integer = number;
                }
            },
            .float => |number| {
                if (!state.seen or
                    (metric.function == .min and number < state.float) or
                    (metric.function == .max and number > state.float))
                {
                    state.float = number;
                }
            },
            else => return error.ObservationAggregateTypeMismatch,
        },
    }
}

fn resolveOperand(
    bindings: *const definition_core.parameters.Bindings,
    definition_plan: *const definition.Plan,
    operand: plan.Operand,
) !execution.Value {
    return switch (operand) {
        .constant => |constant| switch (constant) {
            .string => |value| .{ .string = value },
            .integer => |value| .{ .integer = value },
            .float => |value| .{ .float = value },
            .boolean => |value| .{ .boolean = value },
            .null => .null,
        },
        .parameter => |index| scalarValue(
            bindings.find(definition_plan.parameter_declarations.items[index].name).?.value,
        ),
    };
}

fn scalarValue(value: definition_core.scalar.Value) execution.Value {
    return switch (value) {
        .string, .digest, .timestamp, .safe_identifier, .relative_path => |text| .{
            .string = text,
        },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .boolean = flag },
    };
}

fn valueMatches(
    left: execution.Value,
    right: execution.Value,
    operator: plan.PredicateOperator,
    case_insensitive: bool,
) bool {
    return switch (operator) {
        .exact => valuesEqual(left, right, case_insensitive),
        .not_equal => !valuesEqual(left, right, case_insensitive),
        .contains, .prefix, .suffix => stringMatch(
            left,
            right,
            operator,
            case_insensitive,
        ),
        .less_than => compareValues(left, right) == .lt,
        .less_or_equal => compareValues(left, right) != .gt,
        .greater_than => compareValues(left, right) == .gt,
        .greater_or_equal => compareValues(left, right) != .lt,
    };
}

fn stringMatch(
    left: execution.Value,
    right: execution.Value,
    operator: plan.PredicateOperator,
    case_insensitive: bool,
) bool {
    const a = valueText(left) orelse return false;
    const b = valueText(right) orelse return false;
    if (!case_insensitive) return switch (operator) {
        .contains => std.mem.indexOf(u8, a, b) != null,
        .prefix => std.mem.startsWith(u8, a, b),
        .suffix => std.mem.endsWith(u8, a, b),
        else => false,
    };
    return switch (operator) {
        .contains => std.ascii.indexOfIgnoreCase(a, b) != null,
        .prefix => a.len >= b.len and std.ascii.eqlIgnoreCase(a[0..b.len], b),
        .suffix => a.len >= b.len and std.ascii.eqlIgnoreCase(a[a.len - b.len ..], b),
        else => false,
    };
}

fn limitTable(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    bindings: *const definition_core.parameters.Bindings,
    input: Table,
    limit: plan.Limit,
) !Table {
    const wanted = switch (limit) {
        .fixed => |value| value,
        .parameter => |index| switch (bindings.find(
            definition_plan.parameter_declarations.items[index].name,
        ).?.value) {
            .integer => |value| std.math.cast(usize, value) orelse
                return error.InvalidObservationLimit,
            else => return error.ObservationLimitParameterMustBeInteger,
        },
    };
    const count = @min(wanted, try input.rowCount());
    return .{
        .values = try allocator.dupe(
            execution.Value,
            input.values[0 .. count * input.width],
        ),
        .width = input.width,
    };
}

const SortContext = struct {
    table: Table,
    keys: []const plan.SortKey,

    fn lessThan(context: SortContext, a: usize, b: usize) bool {
        const left = context.table.row(a);
        const right = context.table.row(b);
        for (context.keys) |key| {
            const order = compareNullable(
                left[key.field_index],
                right[key.field_index],
                key.nulls,
            );
            if (order == .eq) continue;
            return if (key.direction == .ascending)
                order == .lt
            else
                order == .gt;
        }
        return a < b;
    }
};

fn sortTable(
    allocator: std.mem.Allocator,
    input: Table,
    sort: plan.Sort,
) !Table {
    const count = try input.rowCount();
    const indices = try allocator.alloc(usize, count);
    defer allocator.free(indices);
    for (indices, 0..) |*index, value| index.* = value;
    std.sort.heap(
        usize,
        indices,
        SortContext{ .table = input, .keys = sort.keys },
        SortContext.lessThan,
    );
    const values = try allocator.alloc(execution.Value, input.values.len);
    for (indices, 0..) |source_index, target_index| {
        @memcpy(
            values[target_index * input.width ..][0..input.width],
            input.row(source_index),
        );
    }
    return .{ .values = values, .width = input.width };
}

fn sortTableInPlace(
    allocator: std.mem.Allocator,
    input: Table,
    sort: plan.Sort,
) !Table {
    const count = try input.rowCount();
    const indices = try allocator.alloc(usize, count);
    defer allocator.free(indices);
    for (indices, 0..) |*index, value| index.* = value;
    std.sort.heap(
        usize,
        indices,
        SortContext{ .table = input, .keys = sort.keys },
        SortContext.lessThan,
    );
    const temporary = try allocator.alloc(execution.Value, input.width);
    defer allocator.free(temporary);
    for (0..count) |start| {
        if (indices[start] == start) continue;
        @memcpy(temporary, input.row(start));
        var current = start;
        var moved: usize = 0;
        while (moved < count) : (moved += 1) {
            const next = indices[current];
            indices[current] = current;
            const target = input.values[current * input.width ..][0..input.width];
            if (next == start) {
                @memcpy(target, temporary);
                break;
            }
            @memcpy(target, input.row(next));
            current = next;
        }
    }
    return input;
}

fn distinctTable(
    allocator: std.mem.Allocator,
    input: Table,
    distinct: plan.Distinct,
) !Table {
    var values: std.ArrayList(execution.Value) = .empty;
    errdefer values.deinit(allocator);
    var heads: std.AutoHashMapUnmanaged(u64, usize) = .{};
    defer heads.deinit(allocator);
    var next: std.ArrayList(usize) = .empty;
    defer next.deinit(allocator);
    for (0..try input.rowCount()) |row_index| {
        const row = input.row(row_index);
        var hasher = std.hash.Wyhash.init(0);
        for (distinct.field_indices) |field| hashValue(&hasher, row[field]);
        const key_hash = hasher.final();
        var duplicate = false;
        var prior = heads.get(key_hash);
        while (prior) |candidate_index| {
            const candidate = values.items[candidate_index * input.width ..][0..input.width];
            var same = true;
            for (distinct.field_indices) |field| {
                if (!valuesEqual(row[field], candidate[field], false)) {
                    same = false;
                    break;
                }
            }
            if (same) {
                duplicate = true;
                break;
            }
            const following = next.items[candidate_index];
            prior = if (following == std.math.maxInt(usize)) null else following;
        }
        if (!duplicate) {
            const retained_index = values.items.len / input.width;
            try values.appendSlice(allocator, row);
            const entry = try heads.getOrPut(allocator, key_hash);
            try next.append(
                allocator,
                if (entry.found_existing) entry.value_ptr.* else std.math.maxInt(usize),
            );
            entry.value_ptr.* = retained_index;
        }
    }
    return .{ .values = try values.toOwnedSlice(allocator), .width = input.width };
}

fn deriveTable(
    allocator: std.mem.Allocator,
    retained_allocator: std.mem.Allocator,
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
    input: Table,
    input_schema: *const plan.Schema,
    output_schema: plan.Schema,
    config: []const u8,
) !Table {
    var workspace: ExpressionWorkspace = .{ .allocator = allocator, .config_bytes = config.len };
    defer workspace.deinit();
    var parsed = try parseConfig(allocator, config);
    defer parsed.deinit();
    const root = try definition_core.json.object(parsed.value);
    const fields = try definition_core.json.array(
        try definition_core.json.field(root, "fields"),
    );
    const preserve_input = if (root.get("preserve_input")) |raw|
        try definition_core.json.boolean(raw)
    else
        true;
    const sequential = if (root.get("sequential")) |raw|
        try definition_core.json.boolean(raw)
    else
        false;
    var expression_arena = std.heap.ArenaAllocator.init(allocator);
    defer expression_arena.deinit();
    const expressions = try expression_arena.allocator().alloc(*CompiledExpr, fields.items.len);
    for (fields.items, 0..) |field, index| {
        const object = try definition_core.json.object(field);
        expressions[index] = try compileExpr(
            expression_arena.allocator(),
            try definition_core.json.field(object, "expr"),
            input_schema,
            if (sequential) &output_schema else null,
            index,
        );
    }
    const values = try allocator.alloc(
        execution.Value,
        (try input.rowCount()) * output_schema.columns.len,
    );
    errdefer allocator.free(values);
    for (0..try input.rowCount()) |row_index| {
        const row = input.row(row_index);
        const out = values[row_index * output_schema.columns.len ..][0..output_schema.columns.len];
        if (preserve_input) @memcpy(out[0..input.width], row);
        for (expressions, 0..) |expression, index| {
            out[(if (preserve_input) input.width else 0) + index] = try evalCompiledExpr(
                &workspace,
                retained_allocator,
                expression,
                row,
                out,
                input_schema,
                bindings,
                selectors,
            );
        }
    }
    return .{ .values = values, .width = output_schema.columns.len };
}

const CompiledOp = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_op,
    or_op,
    add,
    subtract,
    multiply,
    divide,
};

const CompiledExpr = union(enum) {
    null_value,
    boolean: bool,
    integer: i64,
    float: f64,
    text: []const u8,
    field: u16,
    output_field: u16,
    dynamic: std.json.Value,
    is_null: *CompiledExpr,
    not: *CompiledExpr,
    if_else: struct {
        condition: *CompiledExpr,
        then_value: *CompiledExpr,
        else_value: *CompiledExpr,
    },
    coalesce: []*CompiledExpr,
    binary: struct {
        op: CompiledOp,
        left: *CompiledExpr,
        right: *CompiledExpr,
    },
};

const ExpressionCompiler = struct {
    allocator: std.mem.Allocator,
    schema: *const plan.Schema,
    output_schema: ?*const plan.Schema,
    output_limit: usize,
    tasks: std.ArrayList(Task) = .empty,

    const Task = struct { source: std.json.Value, output: *CompiledExpr };

    fn compile(self: *ExpressionCompiler, expression: std.json.Value) !*CompiledExpr {
        const root = try self.allocator.create(CompiledExpr);
        try self.tasks.append(self.allocator, .{ .source = expression, .output = root });
        defer self.tasks.deinit(self.allocator);
        // Each task belongs to one node of the already bounded, parsed config.
        while (self.tasks.pop()) |task| {
            task.output.* = try self.compileNode(task.source);
        }
        return root;
    }

    fn compileNode(self: *ExpressionCompiler, source: std.json.Value) !CompiledExpr {
        return switch (source) {
            .null => .null_value,
            .bool => |value| .{ .boolean = value },
            .integer => |value| .{ .integer = value },
            .float => |value| .{ .float = value },
            .number_string => |value| if (std.fmt.parseInt(i64, value, 10)) |integer|
                .{ .integer = integer }
            else |_|
                .{ .float = try std.fmt.parseFloat(f64, value) },
            .string => |value| .{ .text = value },
            .array => .{ .dynamic = source },
            .object => |object| try self.compileObject(source, object),
        };
    }

    fn compileObject(
        self: *ExpressionCompiler,
        source: std.json.Value,
        object: std.json.ObjectMap,
    ) !CompiledExpr {
        if (object.get("field")) |raw| return self.compileField(raw);
        if (object.get("state") != null or object.get("param") != null or
            object.get("selector") != null)
        {
            return .{ .dynamic = source };
        }
        const op = try definition_core.json.requiredString(object, "op");
        const args = try definition_core.json.array(
            try definition_core.json.field(object, "args"),
        );
        if (std.mem.eql(u8, op, "coalesce")) {
            return .{ .coalesce = try self.children(args.items) };
        }
        if (std.mem.eql(u8, op, "if")) {
            if (args.items.len != 3) return error.InvalidObservationExpressionArity;
            const nodes = try self.children(args.items);
            return .{ .if_else = .{
                .condition = nodes[0],
                .then_value = nodes[1],
                .else_value = nodes[2],
            } };
        }
        if (std.mem.eql(u8, op, "is-null") or std.mem.eql(u8, op, "not")) {
            if (args.items.len != 1) return error.InvalidObservationExpressionArity;
            const nodes = try self.children(args.items);
            return if (std.mem.eql(u8, op, "is-null"))
                .{ .is_null = nodes[0] }
            else
                .{ .not = nodes[0] };
        }
        const compiled_op = parseCompiledOp(op) orelse return .{ .dynamic = source };
        if (args.items.len != 2) return error.InvalidObservationExpressionArity;
        const nodes = try self.children(args.items);
        return .{ .binary = .{ .op = compiled_op, .left = nodes[0], .right = nodes[1] } };
    }

    fn compileField(self: *const ExpressionCompiler, raw: std.json.Value) !CompiledExpr {
        const name = try definition_core.json.string(raw);
        if (self.schema.find(name)) |index| return .{ .field = index };
        if (self.output_schema) |output| {
            for (output.columns[0..self.output_limit], 0..) |column, index| {
                if (std.mem.eql(u8, column.name, name)) {
                    return .{ .output_field = @intCast(index) };
                }
            }
        }
        return error.UnknownObservationExpressionField;
    }

    fn children(self: *ExpressionCompiler, args: []const std.json.Value) ![]*CompiledExpr {
        const nodes = try self.allocator.alloc(*CompiledExpr, args.len);
        for (nodes) |*node| node.* = try self.allocator.create(CompiledExpr);
        var remaining = args.len;
        while (remaining > 0) {
            remaining -= 1;
            try self.tasks.append(self.allocator, .{
                .source = args[remaining],
                .output = nodes[remaining],
            });
        }
        return nodes;
    }
};

fn compileExpr(
    allocator: std.mem.Allocator,
    expression: std.json.Value,
    schema: *const plan.Schema,
    output_schema: ?*const plan.Schema,
    output_limit: usize,
) !*CompiledExpr {
    var compiler: ExpressionCompiler = .{
        .allocator = allocator,
        .schema = schema,
        .output_schema = output_schema,
        .output_limit = output_limit,
    };
    return compiler.compile(expression);
}

fn parseCompiledOp(op: []const u8) ?CompiledOp {
    if (std.mem.eql(u8, op, "eq")) return .eq;
    if (std.mem.eql(u8, op, "ne")) return .ne;
    if (std.mem.eql(u8, op, "lt")) return .lt;
    if (std.mem.eql(u8, op, "le")) return .le;
    if (std.mem.eql(u8, op, "gt")) return .gt;
    if (std.mem.eql(u8, op, "ge")) return .ge;
    if (std.mem.eql(u8, op, "and")) return .and_op;
    if (std.mem.eql(u8, op, "or")) return .or_op;
    if (std.mem.eql(u8, op, "add")) return .add;
    if (std.mem.eql(u8, op, "subtract")) return .subtract;
    if (std.mem.eql(u8, op, "multiply")) return .multiply;
    if (std.mem.eql(u8, op, "divide")) return .divide;
    return null;
}

fn evalCompiledExpr(
    workspace: *ExpressionWorkspace,
    allocator: std.mem.Allocator,
    expression: *const CompiledExpr,
    row: []const execution.Value,
    output: []const execution.Value,
    schema: *const plan.Schema,
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
) !execution.Value {
    return workspace.evaluate(.{ .compiled = expression }, .{
        .allocator = allocator,
        .row = row,
        .output = output,
        .schema = schema,
        .bindings = bindings,
        .selectors = selectors,
    });
}

const JoinContext = struct {
    allocator: std.mem.Allocator,
    left: Table,
    right: Table,
    left_schema: plan.Schema,
    right_schema: plan.Schema,
    output_width: usize,
    on: std.json.ObjectMap,
    keys: std.json.Array,
    fields: std.json.Array,
    kind: []const u8,
    lineage: ?*LineageIndex,
    index: *const JoinIndex,
    max_rows: usize,

    fn first(self: *const JoinContext, row: []const execution.Value) ?usize {
        if (!joinRequiredTrue(self.left_schema, row, self.on, "left_true")) return null;
        const hash = joinEqualityHash(self.left_schema, row, self.keys, true) orelse return null;
        return self.index.first(hash);
    }

    fn matches(
        self: *const JoinContext,
        left: []const execution.Value,
        right: []const execution.Value,
    ) !bool {
        if (!joinKeysMatch(self.left_schema, left, self.right_schema, right, self.keys)) {
            return false;
        }
        if (self.lineage) |lineage| return lineage.matches(left, right);
        return true;
    }

    fn membership(self: *const JoinContext) !Table {
        const keep = try self.allocator.alloc(bool, try self.left.rowCount());
        defer self.allocator.free(keep);
        for (0..keep.len) |left_index| {
            const row = self.left.row(left_index);
            var matched = false;
            var candidate = self.first(row);
            while (candidate) |right_index| : (candidate = self.index.after(right_index)) {
                if (!try self.matches(row, self.right.row(right_index))) continue;
                matched = true;
                break;
            }
            keep[left_index] = if (std.mem.eql(u8, self.kind, "anti")) !matched else matched;
        }
        const aliases_right = self.left.values.ptr == self.right.values.ptr;
        var retained: usize = 0;
        for (keep) |retain| if (retain) {
            retained += 1;
        };
        const output = if (aliases_right)
            try self.allocator.alloc(execution.Value, retained * self.left.width)
        else
            self.left.values;
        var kept: usize = 0;
        for (keep, 0..) |retain, source_index| {
            if (!retain) continue;
            if (aliases_right or kept != source_index) {
                @memcpy(
                    output[kept * self.left.width ..][0..self.left.width],
                    self.left.row(source_index),
                );
            }
            kept += 1;
        }
        return .{ .values = output[0 .. kept * self.left.width], .width = self.left.width };
    }

    fn materialize(self: *const JoinContext, membership_join: bool) !Table {
        if (membership_join and !joinProjectsOnlyLeft(self.fields)) {
            return error.ObservationMembershipJoinProjectsRight;
        }
        var values: std.ArrayList(execution.Value) = .empty;
        errdefer values.deinit(self.allocator);
        for (0..try self.left.rowCount()) |left_index| {
            const row = self.left.row(left_index);
            var matched = false;
            var candidate = self.first(row);
            while (candidate) |right_index| : (candidate = self.index.after(right_index)) {
                const right = self.right.row(right_index);
                if (!try self.matches(row, right)) continue;
                matched = true;
                if (membership_join) break;
                try self.append(&values, row, right);
                if (values.items.len / self.output_width > self.max_rows) {
                    return error.ObservationRowBoundExceeded;
                }
            }
            if (membership_join) {
                const retain = if (std.mem.eql(u8, self.kind, "anti")) !matched else matched;
                if (retain) try self.append(&values, row, null);
            } else if (!matched and std.mem.eql(u8, self.kind, "left")) {
                try self.append(&values, row, null);
            }
        }
        return .{ .values = try values.toOwnedSlice(self.allocator), .width = self.output_width };
    }

    fn append(
        self: *const JoinContext,
        values: *std.ArrayList(execution.Value),
        left: []const execution.Value,
        right: ?[]const execution.Value,
    ) !void {
        try appendJoinRow(
            self.allocator,
            values,
            self.fields,
            self.left_schema,
            left,
            self.right_schema,
            right,
        );
    }
};

fn joinTable(
    allocator: std.mem.Allocator,
    native_plan: *const plan.Plan,
    step: definition.Step,
    tables: []const ?Table,
    output_schema: plan.Schema,
    config: []const u8,
    bounds: definition.Bounds,
) !Table {
    if (step.input_names.len < 2 or step.input_names.len > 3) {
        return error.InvalidPipelineInputCount;
    }
    const left_index = native_plan.findStage(step.input_names[0]) orelse
        return error.ObservationExternalGraphInputUnsupported;
    const right_index = native_plan.findStage(step.input_names[1]) orelse
        return error.ObservationExternalGraphInputUnsupported;
    const left = tables[left_index] orelse return error.ObservationInputNotExecuted;
    const right = tables[right_index] orelse return error.ObservationInputNotExecuted;
    var parsed = try parseConfig(allocator, config);
    defer parsed.deinit();
    const root = try definition_core.json.object(parsed.value);
    const on = try definition_core.json.object(try definition_core.json.field(root, "on"));
    const keys = try definition_core.json.array(try definition_core.json.field(on, "keys"));
    const kind = if (on.get("kind")) |raw| try definition_core.json.string(raw) else "inner";
    const fields = try definition_core.json.array(try definition_core.json.field(root, "fields"));
    var lineage = try initJoinLineage(
        allocator,
        native_plan,
        step,
        tables,
        on,
        left_index,
        right_index,
        bounds.max_graph_depth,
    );
    defer if (lineage) |*index| index.deinit(allocator);
    var index = try JoinIndex.init(allocator, try right.rowCount());
    defer index.deinit(allocator);
    try populateJoinIndex(
        allocator,
        &index,
        right,
        native_plan.stages[right_index].schema,
        on,
        keys,
    );
    const context: JoinContext = .{
        .allocator = allocator,
        .left = left,
        .right = right,
        .left_schema = native_plan.stages[left_index].schema,
        .right_schema = native_plan.stages[right_index].schema,
        .output_width = output_schema.columns.len,
        .on = on,
        .keys = keys,
        .fields = fields,
        .kind = kind,
        .lineage = if (lineage) |*value| value else null,
        .index = &index,
        .max_rows = bounds.max_rows,
    };
    const membership_join = std.mem.eql(u8, kind, "semi") or std.mem.eql(u8, kind, "anti");
    if (membership_join and joinProjectsLeft(fields, context.left_schema)) {
        return context.membership();
    }
    return context.materialize(membership_join);
}

fn initJoinLineage(
    allocator: std.mem.Allocator,
    native_plan: *const plan.Plan,
    step: definition.Step,
    tables: []const ?Table,
    on: std.json.ObjectMap,
    left_index: u16,
    right_index: u16,
    max_depth: usize,
) !?LineageIndex {
    const raw = on.get("lineage") orelse return null;
    if (step.input_names.len != 3) return error.ObservationLineageInputMissing;
    const graph_index = native_plan.findStage(step.input_names[2]) orelse
        return error.ObservationExternalGraphInputUnsupported;
    const graph = tables[graph_index] orelse return error.ObservationInputNotExecuted;
    return try LineageIndex.init(
        allocator,
        graph,
        native_plan.stages[graph_index].schema,
        try definition_core.json.object(raw),
        native_plan.stages[left_index].schema,
        native_plan.stages[right_index].schema,
        max_depth,
    );
}

fn populateJoinIndex(
    allocator: std.mem.Allocator,
    index: *JoinIndex,
    right: Table,
    schema: plan.Schema,
    on: std.json.ObjectMap,
    keys: std.json.Array,
) !void {
    var equality_keys: usize = 0;
    for (keys.items) |item| {
        const key = try definition_core.json.object(item);
        const op = if (key.get("op")) |raw| try definition_core.json.string(raw) else "eq";
        if (std.mem.eql(u8, op, "eq")) equality_keys += 1;
    }
    if (equality_keys == 0) return error.ObservationJoinRequiresEqualityKey;
    for (0..try right.rowCount()) |row_index| {
        const row = right.row(row_index);
        if (!joinRequiredTrue(schema, row, on, "right_true")) continue;
        const hash = joinEqualityHash(schema, row, keys, false) orelse continue;
        try index.add(allocator, hash, row_index);
    }
}

fn joinProjectsOnlyLeft(fields: std.json.Array) bool {
    for (fields.items) |item| {
        const field = definition_core.json.object(item) catch return false;
        const source = definition_core.json.unsigned(
            definition_core.json.field(field, "source") catch return false,
        ) catch return false;
        if (source != 0) return false;
    }
    return true;
}

fn joinProjectsLeft(fields: std.json.Array, schema: plan.Schema) bool {
    if (fields.items.len != schema.columns.len) return false;
    for (fields.items, 0..) |item, index| {
        const field = definition_core.json.object(item) catch return false;
        const source = definition_core.json.unsigned(
            definition_core.json.field(field, "source") catch return false,
        ) catch return false;
        if (source != 0) return false;
        const name = definition_core.json.requiredString(field, "field") catch return false;
        if (!std.mem.eql(u8, name, schema.columns[index].name)) return false;
    }
    return true;
}

const CompiledJoinKey = struct {
    left: u16,
    right: u16,
    nulls_equal: bool,
};

fn joinTrueFieldIndex(on: std.json.ObjectMap, schema: plan.Schema, key: []const u8) !?u16 {
    const raw = on.get(key) orelse return null;
    return schema.find(try definition_core.json.string(raw)) orelse
        error.UnknownObservationJoinField;
}

fn compileStreamingJoinKeys(
    allocator: std.mem.Allocator,
    on: std.json.ObjectMap,
    left_schema: plan.Schema,
) ![]CompiledJoinKey {
    const raw_keys = try definition_core.json.array(try definition_core.json.field(on, "keys"));
    const keys = try allocator.alloc(CompiledJoinKey, raw_keys.items.len);
    errdefer allocator.free(keys);
    for (raw_keys.items, 0..) |item, index| {
        const key = try definition_core.json.object(item);
        const op = if (key.get("op")) |raw|
            try definition_core.json.string(raw)
        else
            "eq";
        if (!std.mem.eql(u8, op, "eq")) {
            return error.ObservationStreamingLineageKeyUnsupported;
        }
        keys[index] = .{
            .left = left_schema.find(
                try definition_core.json.requiredString(key, "left"),
            ) orelse return error.UnknownObservationJoinField,
            .right = left_schema.find(
                try definition_core.json.requiredString(key, "right"),
            ) orelse return error.UnknownObservationJoinField,
            .nulls_equal = if (key.get("nulls_equal")) |raw|
                try definition_core.json.boolean(raw)
            else
                false,
        };
    }
    return keys;
}

pub const StreamingLineageReducer = struct {
    allocator: std.mem.Allocator,
    left_schema: plan.Schema,
    output_width: usize,
    keys: []CompiledJoinKey,
    lineage: LineageIndex,
    heads: std.AutoHashMapUnmanaged(u64, usize) = .{},
    next: std.ArrayList(usize) = .empty,
    output: std.ArrayList(execution.Value) = .empty,
    left_true_index: ?u16,
    right_true_index: ?u16,
    max_rows: usize,
    max_retained_bytes: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        definition_plan: *const definition.Plan,
        native_plan: *const plan.Plan,
        schedule: StreamingLineagePlan,
        graph: Table,
        max_retained_bytes: usize,
    ) !StreamingLineageReducer {
        const stage = native_plan.stages[schedule.lineage_stage];
        const generic = switch (stage.operation) {
            .generic => |value| value,
            else => return error.ObservationStreamingLineageShapeUnsupported,
        };
        if (generic.operator != .join) return error.ObservationStreamingLineageShapeUnsupported;
        var parsed = try parseConfig(allocator, generic.canonical_config);
        defer parsed.deinit();
        const root = try definition_core.json.object(parsed.value);
        const on = try definition_core.json.object(
            try definition_core.json.field(root, "on"),
        );
        const kind = try definition_core.json.requiredString(on, "kind");
        if (!std.mem.eql(u8, kind, "anti")) {
            return error.ObservationStreamingLineageShapeUnsupported;
        }
        const fields = try definition_core.json.array(
            try definition_core.json.field(root, "fields"),
        );
        const left_schema = native_plan.stages[schedule.local_stage].schema;
        if (!joinProjectsLeft(fields, left_schema)) {
            return error.ObservationStreamingLineageProjectionUnsupported;
        }
        const keys = try compileStreamingJoinKeys(allocator, on, left_schema);
        errdefer allocator.free(keys);
        const lineage_config = try definition_core.json.object(
            on.get("lineage") orelse return error.ObservationLineageInputMissing,
        );
        var lineage = try LineageIndex.init(
            allocator,
            graph,
            native_plan.stages[schedule.graph_stage].schema,
            lineage_config,
            left_schema,
            left_schema,
            definition_plan.bounds.max_graph_depth,
        );
        errdefer lineage.deinit(allocator);
        const left_true = try joinTrueFieldIndex(on, left_schema, "left_true");
        const right_true = try joinTrueFieldIndex(on, left_schema, "right_true");
        return .{
            .allocator = allocator,
            .left_schema = left_schema,
            .output_width = stage.schema.columns.len,
            .keys = keys,
            .lineage = lineage,
            .left_true_index = left_true,
            .right_true_index = right_true,
            .max_rows = definition_plan.bounds.max_rows,
            .max_retained_bytes = max_retained_bytes,
        };
    }

    pub fn deinit(self: *StreamingLineageReducer) void {
        self.lineage.deinit(self.allocator);
        self.allocator.free(self.keys);
        self.heads.deinit(self.allocator);
        self.next.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendPartition(self: *StreamingLineageReducer, rows: Table) !void {
        if (rows.width != self.left_schema.columns.len) {
            return error.InvalidObservationRows;
        }
        for (0..try rows.rowCount()) |row_index| {
            const row = rows.row(row_index);
            const left_enabled = if (self.left_true_index) |index|
                switch (row[index]) {
                    .boolean => |flag| flag,
                    else => false,
                }
            else
                true;
            if (!left_enabled) {
                try self.output.appendSlice(self.allocator, row);
                try self.next.append(self.allocator, std.math.maxInt(usize));
                try self.checkBounds();
                continue;
            }
            const key_hash = self.keyHash(row) orelse {
                try self.output.appendSlice(self.allocator, row);
                try self.next.append(self.allocator, std.math.maxInt(usize));
                try self.checkBounds();
                continue;
            };
            var matched_ancestor = false;
            var candidate = self.heads.get(key_hash);
            while (candidate) |owner_index| {
                const owner = self.ownerRow(owner_index);
                if (self.keysMatch(row, owner) and
                    try self.lineage.matches(row, owner))
                {
                    matched_ancestor = true;
                    break;
                }
                const following = self.next.items[owner_index];
                candidate = if (following == std.math.maxInt(usize)) null else following;
            }
            if (matched_ancestor) continue;
            const right_enabled = if (self.right_true_index) |index|
                switch (row[index]) {
                    .boolean => |flag| flag,
                    else => false,
                }
            else
                true;
            const output_index = self.output.items.len / self.output_width;
            try self.output.appendSlice(self.allocator, row);
            if (right_enabled) {
                const entry = try self.heads.getOrPut(self.allocator, key_hash);
                try self.next.append(
                    self.allocator,
                    if (entry.found_existing) entry.value_ptr.* else std.math.maxInt(usize),
                );
                entry.value_ptr.* = output_index;
            } else try self.next.append(self.allocator, std.math.maxInt(usize));
            try self.checkBounds();
        }
    }

    fn checkBounds(self: *const StreamingLineageReducer) !void {
        if (self.output.items.len / self.output_width > self.max_rows) {
            return error.ObservationRowBoundExceeded;
        }
        const value_bytes = try std.math.mul(
            usize,
            self.output.items.len,
            @sizeOf(execution.Value),
        );
        const next_bytes = try std.math.mul(usize, self.next.items.len, @sizeOf(usize));
        if (try std.math.add(usize, value_bytes, next_bytes) > self.max_retained_bytes) {
            return error.ObservationRetainedByteBoundExceeded;
        }
    }

    pub fn finish(self: *StreamingLineageReducer) !Table {
        const values = try self.output.toOwnedSlice(self.allocator);
        self.output = .empty;
        return .{ .values = values, .width = self.output_width };
    }

    fn ownerRow(self: *const StreamingLineageReducer, index: usize) []const execution.Value {
        const width = self.left_schema.columns.len;
        return self.output.items[index * width ..][0..width];
    }

    fn keyHash(self: *const StreamingLineageReducer, row: []const execution.Value) ?u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (self.keys) |key| {
            const value = row[key.left];
            if (value == .null and !key.nulls_equal) return null;
            hashValue(&hasher, value);
        }
        return hasher.final();
    }

    fn keysMatch(
        self: *const StreamingLineageReducer,
        left: []const execution.Value,
        right: []const execution.Value,
    ) bool {
        for (self.keys) |key| {
            if (left[key.left] == .null or right[key.right] == .null) {
                if (key.nulls_equal and left[key.left] == .null and right[key.right] == .null) {
                    continue;
                }
                return false;
            }
            if (!valuesEqual(left[key.left], right[key.right], false)) return false;
        }
        return true;
    }
};

const JoinIndex = struct {
    const none = std.math.maxInt(usize);
    heads: std.AutoHashMapUnmanaged(u64, usize) = .{},
    next: []usize,

    fn init(allocator: std.mem.Allocator, count: usize) !JoinIndex {
        const next = try allocator.alloc(usize, count);
        @memset(next, none);
        return .{ .next = next };
    }

    fn deinit(self: *JoinIndex, allocator: std.mem.Allocator) void {
        self.heads.deinit(allocator);
        allocator.free(self.next);
        self.* = undefined;
    }

    fn add(
        self: *JoinIndex,
        allocator: std.mem.Allocator,
        hash: u64,
        row_index: usize,
    ) !void {
        const entry = try self.heads.getOrPut(allocator, hash);
        self.next[row_index] = if (entry.found_existing) entry.value_ptr.* else none;
        entry.value_ptr.* = row_index;
    }

    fn first(self: *const JoinIndex, hash: u64) ?usize {
        return self.heads.get(hash);
    }

    fn after(self: *const JoinIndex, row_index: usize) ?usize {
        const next = self.next[row_index];
        return if (next == none) null else next;
    }
};

fn joinRequiredTrue(
    schema: plan.Schema,
    row: []const execution.Value,
    on: std.json.ObjectMap,
    name: []const u8,
) bool {
    const raw = on.get(name) orelse return true;
    const field = definition_core.json.string(raw) catch return false;
    return switch (row[schema.find(field) orelse return false]) {
        .boolean => |flag| flag,
        else => false,
    };
}

fn joinEqualityHash(
    schema: plan.Schema,
    row: []const execution.Value,
    keys: std.json.Array,
    left: bool,
) ?u64 {
    var hash = std.hash.Wyhash.init(0);
    var count: usize = 0;
    for (keys.items) |item| {
        const key = definition_core.json.object(item) catch return null;
        const op = if (key.get("op")) |raw|
            definition_core.json.string(raw) catch return null
        else
            "eq";
        if (!std.mem.eql(u8, op, "eq")) continue;
        const name = definition_core.json.requiredString(
            key,
            if (left) "left" else "right",
        ) catch return null;
        const value = row[schema.find(name) orelse return null];
        if (value == .null) {
            const nulls_equal = if (key.get("nulls_equal")) |raw|
                definition_core.json.boolean(raw) catch return null
            else
                false;
            if (!nulls_equal) return null;
        }
        hashValue(&hash, value);
        count += 1;
    }
    return if (count == 0) null else hash.final();
}

fn hashValue(hash: *std.hash.Wyhash, value: execution.Value) void {
    if (valueFloat(value)) |number| {
        const bits: u64 = @bitCast(number);
        hash.update(std.mem.asBytes(&bits));
        return;
    }
    switch (value) {
        .string, .json => |text| {
            const len: u64 = text.len;
            hash.update(std.mem.asBytes(&len));
            hash.update(text);
        },
        .boolean => |flag| {
            const byte: u8 = @intFromBool(flag);
            hash.update(&.{byte});
        },
        .null => {},
        else => unreachable,
    }
}

const LineageIndex = struct {
    rows: Table,
    node_index: u16,
    parent_index: u16,
    left_index: u16,
    right_index: u16,
    max_depth: usize,
    nodes: std.StringHashMapUnmanaged(usize) = .{},

    fn init(
        allocator: std.mem.Allocator,
        rows: Table,
        graph_schema: plan.Schema,
        config: std.json.ObjectMap,
        left_schema: plan.Schema,
        right_schema: plan.Schema,
        max_depth: usize,
    ) !LineageIndex {
        var result = LineageIndex{
            .rows = rows,
            .node_index = graph_schema.find(
                try definition_core.json.requiredString(config, "node"),
            ) orelse return error.UnknownObservationLineageField,
            .parent_index = graph_schema.find(
                try definition_core.json.requiredString(config, "parent"),
            ) orelse return error.UnknownObservationLineageField,
            .left_index = left_schema.find(
                try definition_core.json.requiredString(config, "left"),
            ) orelse return error.UnknownObservationLineageField,
            .right_index = right_schema.find(
                try definition_core.json.requiredString(config, "right"),
            ) orelse return error.UnknownObservationLineageField,
            .max_depth = max_depth,
        };
        errdefer result.deinit(allocator);
        for (0..try rows.rowCount()) |row_index| {
            const node = valueText(rows.row(row_index)[result.node_index]) orelse
                return error.InvalidObservationLineageNode;
            const entry = try result.nodes.getOrPut(allocator, node);
            if (entry.found_existing) return error.DuplicateObservationLineageNode;
            entry.value_ptr.* = row_index;
        }
        return result;
    }

    fn deinit(self: *LineageIndex, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.* = undefined;
    }

    fn matches(
        self: *const LineageIndex,
        left: []const execution.Value,
        right: []const execution.Value,
    ) !bool {
        const descendant = valueText(left[self.left_index]) orelse return false;
        const ancestor = valueText(right[self.right_index]) orelse return false;
        var current = descendant;
        var depth: usize = 0;
        while (self.nodes.get(current)) |row_index| {
            if (depth >= self.max_depth) return error.ObservationGraphDepthExceeded;
            const parent = valueText(self.rows.row(row_index)[self.parent_index]) orelse
                return false;
            depth += 1;
            if (std.mem.eql(u8, parent, ancestor)) return true;
            if (std.mem.eql(u8, parent, current)) return error.ObservationGraphCycle;
            current = parent;
        }
        return false;
    }
};

fn joinKeysMatch(
    left_schema: plan.Schema,
    left: []const execution.Value,
    right_schema: plan.Schema,
    right: []const execution.Value,
    keys: std.json.Array,
) bool {
    for (keys.items) |item| {
        const key = definition_core.json.object(item) catch return false;
        const left_name = definition_core.json.requiredString(key, "left") catch return false;
        const right_name = definition_core.json.requiredString(key, "right") catch return false;
        const left_index = left_schema.find(left_name) orelse return false;
        const right_index = right_schema.find(right_name) orelse return false;
        const nulls_equal = if (key.get("nulls_equal")) |raw|
            definition_core.json.boolean(raw) catch return false
        else
            false;
        if (left[left_index] == .null or right[right_index] == .null) {
            if (nulls_equal and left[left_index] == .null and right[right_index] == .null) {
                continue;
            }
            return false;
        }
        const op = if (key.get("op")) |raw|
            definition_core.json.string(raw) catch return false
        else
            "eq";
        const matched = if (std.mem.eql(u8, op, "eq"))
            valuesEqual(left[left_index], right[right_index], false)
        else if (std.mem.eql(u8, op, "lt"))
            compareValues(left[left_index], right[right_index]) == .lt
        else if (std.mem.eql(u8, op, "le"))
            compareValues(left[left_index], right[right_index]) != .gt
        else if (std.mem.eql(u8, op, "gt"))
            compareValues(left[left_index], right[right_index]) == .gt
        else if (std.mem.eql(u8, op, "ge"))
            compareValues(left[left_index], right[right_index]) != .lt
        else
            false;
        if (!matched) return false;
    }
    return true;
}

fn appendJoinRow(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(execution.Value),
    fields: std.json.Array,
    left_schema: plan.Schema,
    left: []const execution.Value,
    right_schema: plan.Schema,
    right: ?[]const execution.Value,
) !void {
    for (fields.items) |item| {
        const field = try definition_core.json.object(item);
        const source = try definition_core.json.unsigned(
            try definition_core.json.field(field, "source"),
        );
        const name = try definition_core.json.requiredString(field, "field");
        const value: execution.Value = if (source == 0)
            left[left_schema.find(name) orelse return error.UnknownObservationJoinField]
        else if (source == 1 and right != null)
            right.?[right_schema.find(name) orelse return error.UnknownObservationJoinField]
        else
            .null;
        try output.append(allocator, value);
    }
}

fn configArray(object: std.json.ObjectMap, name: []const u8) !std.json.Array {
    return definition_core.json.array(try definition_core.json.field(object, name));
}

fn orderedFoldTable(
    allocator: std.mem.Allocator,
    retained_allocator: std.mem.Allocator,
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
    input: Table,
    input_schema: *const plan.Schema,
    output_schema: plan.Schema,
    config: []const u8,
    max_states: usize,
) !Table {
    var workspace: ExpressionWorkspace = .{ .allocator = allocator, .config_bytes = config.len };
    defer workspace.deinit();
    var parsed = try parseConfig(allocator, config);
    defer parsed.deinit();
    const root = try definition_core.json.object(parsed.value);
    const keys = try stringFieldIndices(
        allocator,
        input_schema,
        try definition_core.json.array(
            try definition_core.json.field(root, "keys"),
        ),
    );
    defer allocator.free(keys);
    const order = try compileDynamicSort(
        allocator,
        input_schema,
        try definition_core.json.array(
            try definition_core.json.field(root, "order_by"),
        ),
    );
    defer allocator.free(order);
    const sorted = try sortTableInPlace(allocator, input, .{ .keys = order });
    const state_defs = try configArray(root, "state");
    if (state_defs.items.len > max_states) return error.ObservationFoldStateBoundExceeded;
    const transitions = try configArray(root, "transitions");
    const emit = try configArray(root, "emit");
    var scratch = try FoldScratch.init(allocator, state_defs.items.len, keys.len, emit.items.len);
    defer scratch.deinit(allocator);
    const in_place = output_schema.columns.len <= input.width;
    const output_values = if (in_place)
        input.values
    else
        try allocator.alloc(
            execution.Value,
            (try sorted.rowCount()) * output_schema.columns.len,
        );
    errdefer if (!in_place) allocator.free(output_values);
    var fold: FoldExecution = .{
        .workspace = &workspace,
        .allocator = retained_allocator,
        .bindings = bindings,
        .selectors = selectors,
        .input_schema = input_schema,
        .state_defs = state_defs,
        .transitions = transitions,
        .emit = emit,
        .keys = keys,
        .scratch = &scratch,
    };
    try fold.run(sorted, output_values, output_schema.columns.len);
    return .{
        .values = output_values[0 .. (try sorted.rowCount()) * output_schema.columns.len],
        .width = output_schema.columns.len,
    };
}

const FoldScratch = struct {
    state: []execution.Value,
    state_names: [][]const u8,
    current_key: []execution.Value,
    emit_values: []execution.Value,
    previous: []execution.Value,

    fn init(allocator: std.mem.Allocator, states: usize, keys: usize, emit: usize) !FoldScratch {
        const state = try allocator.alloc(execution.Value, states);
        errdefer allocator.free(state);
        const names = try allocator.alloc([]const u8, states);
        errdefer allocator.free(names);
        const current_key = try allocator.alloc(execution.Value, keys);
        errdefer allocator.free(current_key);
        const emit_values = try allocator.alloc(execution.Value, emit);
        errdefer allocator.free(emit_values);
        const previous = try allocator.alloc(execution.Value, states);
        return .{
            .state = state,
            .state_names = names,
            .current_key = current_key,
            .emit_values = emit_values,
            .previous = previous,
        };
    }

    fn deinit(self: *FoldScratch, allocator: std.mem.Allocator) void {
        allocator.free(self.previous);
        allocator.free(self.emit_values);
        allocator.free(self.current_key);
        allocator.free(self.state_names);
        allocator.free(self.state);
    }
};

const FoldExecution = struct {
    workspace: *ExpressionWorkspace,
    allocator: std.mem.Allocator,
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
    input_schema: *const plan.Schema,
    state_defs: std.json.Array,
    transitions: std.json.Array,
    emit: std.json.Array,
    keys: []const u16,
    scratch: *FoldScratch,

    fn run(self: *FoldExecution, sorted: Table, output: []execution.Value, width: usize) !void {
        var has_current_key = false;
        for (0..try sorted.rowCount()) |row_index| {
            const row = sorted.row(row_index);
            if (!has_current_key or !rowMatchesKey(row, self.scratch.current_key, self.keys)) {
                for (self.keys, 0..) |key, index| self.scratch.current_key[index] = row[key];
                has_current_key = true;
                try self.initializePartition(row);
            }
            try self.transition(row);
            for (self.emit.items, 0..) |item, index| {
                const field = try definition_core.json.object(item);
                self.scratch.emit_values[index] = try self.evaluate(
                    row,
                    try definition_core.json.field(field, "expr"),
                    self.scratch.state,
                );
            }
            @memcpy(output[row_index * width ..][0..width], self.scratch.emit_values);
        }
    }

    fn initializePartition(self: *FoldExecution, row: []const execution.Value) !void {
        for (self.state_defs.items, 0..) |item, index| {
            const object = try definition_core.json.object(item);
            self.scratch.state_names[index] = try definition_core.json.requiredString(
                object,
                "name",
            );
            self.scratch.state[index] = try self.evaluate(
                row,
                try definition_core.json.field(object, "initial"),
                self.scratch.state,
            );
        }
    }

    fn transition(self: *FoldExecution, row: []const execution.Value) !void {
        @memcpy(self.scratch.previous, self.scratch.state);
        for (self.transitions.items) |item| {
            const step = try definition_core.json.object(item);
            const name = try definition_core.json.requiredString(step, "state");
            const index = findName(self.scratch.state_names, name) orelse
                return error.UnknownObservationFoldState;
            self.scratch.state[index] = try self.evaluate(
                row,
                try definition_core.json.field(step, "expr"),
                self.scratch.previous,
            );
        }
    }

    fn evaluate(
        self: *FoldExecution,
        row: []const execution.Value,
        expression: std.json.Value,
        state: []const execution.Value,
    ) !execution.Value {
        return evalExpr(
            self.workspace,
            self.allocator,
            expression,
            row,
            self.input_schema,
            state,
            self.scratch.state_names,
            self.bindings,
            self.selectors,
        );
    }
};

fn rowMatchesKey(
    row: []const execution.Value,
    current_key: []const execution.Value,
    keys: []const u16,
) bool {
    for (keys, 0..) |field, index| {
        if (!valuesEqual(row[field], current_key[index], false)) return false;
    }
    return true;
}

fn reachabilityTable(
    allocator: std.mem.Allocator,
    input: Table,
    input_schema: *const plan.Schema,
    output_schema: plan.Schema,
    config: []const u8,
    bounds: definition.Bounds,
) !Table {
    var parsed = try parseConfig(allocator, config);
    defer parsed.deinit();
    const root = try definition_core.json.object(parsed.value);
    const keys = try definition_core.json.object(
        try definition_core.json.field(root, "keys"),
    );
    const node_index = input_schema.find(
        try definition_core.json.requiredString(keys, "node"),
    ) orelse return error.UnknownObservationReachabilityField;
    const parent_index = input_schema.find(
        try definition_core.json.requiredString(keys, "parent"),
    ) orelse return error.UnknownObservationReachabilityField;
    const fields = try definition_core.json.array(
        try definition_core.json.field(root, "fields"),
    );
    const count = try input.rowCount();
    if (count > bounds.max_graph_nodes) return error.ObservationGraphNodeBoundExceeded;
    var nodes: std.StringHashMapUnmanaged(usize) = .{};
    defer nodes.deinit(allocator);
    for (0..count) |index| {
        const node = valueText(input.row(index)[node_index]) orelse
            return error.InvalidObservationReachabilityNode;
        const entry = try nodes.getOrPut(allocator, node);
        if (entry.found_existing) return error.DuplicateObservationReachabilityNode;
        entry.value_ptr.* = index;
    }
    if (keys.get("mode")) |raw_mode| {
        const mode = try definition_core.json.string(raw_mode);
        if (std.mem.eql(u8, mode, "closure")) {
            return reachabilityClosure(
                allocator,
                input,
                input_schema,
                output_schema,
                fields,
                node_index,
                parent_index,
                bounds,
                &nodes,
            );
        }
        return error.UnknownObservationReachabilityMode;
    }
    return reachabilitySeeded(
        allocator,
        input,
        input_schema,
        output_schema,
        fields,
        keys,
        parent_index,
        bounds,
        &nodes,
    );
}

fn reachabilitySeeded(
    allocator: std.mem.Allocator,
    input: Table,
    input_schema: *const plan.Schema,
    output_schema: plan.Schema,
    fields: std.json.Array,
    keys: std.json.ObjectMap,
    parent_index: u16,
    bounds: definition.Bounds,
    nodes: *const std.StringHashMapUnmanaged(usize),
) !Table {
    const count = try input.rowCount();
    const seed_index = input_schema.find(
        try definition_core.json.requiredString(keys, "seed"),
    ) orelse return error.UnknownObservationReachabilityField;
    const direction = if (keys.get("direction")) |raw|
        try definition_core.json.string(raw)
    else
        "ancestors";
    const walk_ancestors = std.mem.eql(u8, direction, "ancestors") or
        std.mem.eql(u8, direction, "both");
    const walk_descendants = std.mem.eql(u8, direction, "descendants") or
        std.mem.eql(u8, direction, "both");
    if (!walk_ancestors and !walk_descendants) {
        return error.UnknownObservationReachabilityDirection;
    }
    const reachable = try allocator.alloc(bool, count);
    defer allocator.free(reachable);
    const depths = try allocator.alloc(i64, count);
    defer allocator.free(depths);
    @memset(reachable, false);
    @memset(depths, -1);
    for (0..count) |index| switch (input.row(index)[seed_index]) {
        .boolean => |seed| if (seed) {
            reachable[index] = true;
            depths[index] = 0;
        },
        else => {},
    };
    try expandReachability(
        input,
        parent_index,
        bounds.max_graph_depth,
        nodes,
        walk_ancestors,
        walk_descendants,
        reachable,
        depths,
    );
    return projectReachability(
        allocator,
        input,
        input_schema,
        output_schema,
        fields,
        reachable,
        depths,
    );
}

fn expandReachability(
    input: Table,
    parent_index: u16,
    max_depth: usize,
    nodes: *const std.StringHashMapUnmanaged(usize),
    walk_ancestors: bool,
    walk_descendants: bool,
    reachable: []bool,
    depths: []i64,
) !void {
    const count = try input.rowCount();
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        var changed = false;
        for (0..count) |child_index| {
            const parent = input.row(child_index)[parent_index];
            if (parent == .null) continue;
            const parent_text = valueText(parent) orelse
                return error.InvalidObservationReachabilityNode;
            if (nodes.get(parent_text)) |candidate_index| {
                if (walk_ancestors and reachable[child_index] and
                    !reachable[candidate_index])
                {
                    reachable[candidate_index] = true;
                    depths[candidate_index] = depths[child_index] + 1;
                    changed = true;
                }
                if (walk_descendants and reachable[candidate_index] and
                    !reachable[child_index])
                {
                    reachable[child_index] = true;
                    depths[child_index] = depths[candidate_index] + 1;
                    changed = true;
                }
            }
        }
        if (!changed) break;
    }
}

fn projectReachability(
    allocator: std.mem.Allocator,
    input: Table,
    input_schema: *const plan.Schema,
    output_schema: plan.Schema,
    fields: std.json.Array,
    reachable: []const bool,
    depths: []const i64,
) !Table {
    const count = try input.rowCount();
    var output: std.ArrayList(execution.Value) = .empty;
    errdefer output.deinit(allocator);
    for (0..count) |row_index| {
        const row = input.row(row_index);
        for (fields.items) |item| {
            const field = try definition_core.json.object(item);
            if (field.get("meta")) |raw| {
                const meta = try definition_core.json.string(raw);
                try output.append(
                    allocator,
                    if (std.mem.eql(u8, meta, "reachable"))
                        .{ .boolean = reachable[row_index] }
                    else if (std.mem.eql(u8, meta, "depth"))
                        if (depths[row_index] < 0) .null else .{ .integer = depths[row_index] }
                    else
                        return error.UnknownObservationReachabilityMeta,
                );
            } else {
                const name = try definition_core.json.requiredString(field, "field");
                try output.append(
                    allocator,
                    row[
                        input_schema.find(name) orelse
                            return error.UnknownObservationReachabilityField
                    ],
                );
            }
        }
    }
    return .{ .values = try output.toOwnedSlice(allocator), .width = output_schema.columns.len };
}

fn reachabilityClosure(
    allocator: std.mem.Allocator,
    input: Table,
    input_schema: *const plan.Schema,
    output_schema: plan.Schema,
    fields: std.json.Array,
    node_index: u16,
    parent_index: u16,
    bounds: definition.Bounds,
    nodes: *const std.StringHashMapUnmanaged(usize),
) !Table {
    const count = try input.rowCount();
    var output: std.ArrayList(execution.Value) = .empty;
    errdefer output.deinit(allocator);
    for (0..count) |descendant_index| {
        const descendant = input.row(descendant_index);
        var parent = descendant[parent_index];
        var depth: usize = 1;
        while (parent != .null) : (depth += 1) {
            if (depth > bounds.max_graph_depth) {
                return error.ObservationGraphDepthExceeded;
            }
            const parent_text = valueText(parent) orelse
                return error.InvalidObservationReachabilityNode;
            const found = nodes.get(parent_text) orelse break;
            const ancestor = input.row(found);
            if (valuesEqual(
                descendant[node_index],
                ancestor[node_index],
                false,
            )) return error.ObservationGraphCycle;
            for (fields.items) |item| {
                const field = try definition_core.json.object(item);
                if (field.get("meta")) |raw| {
                    const meta = try definition_core.json.string(raw);
                    try output.append(
                        allocator,
                        if (std.mem.eql(u8, meta, "descendant"))
                            descendant[node_index]
                        else if (std.mem.eql(u8, meta, "ancestor"))
                            ancestor[node_index]
                        else if (std.mem.eql(u8, meta, "depth"))
                            .{ .integer = @intCast(depth) }
                        else
                            return error.UnknownObservationReachabilityMeta,
                    );
                } else {
                    const name = try definition_core.json.requiredString(field, "field");
                    try output.append(
                        allocator,
                        ancestor[
                            input_schema.find(name) orelse
                                return error.UnknownObservationReachabilityField
                        ],
                    );
                }
            }
            if (output.items.len / output_schema.columns.len > bounds.max_rows or
                output.items.len / output_schema.columns.len > bounds.max_graph_nodes)
            {
                return error.ObservationGraphNodeBoundExceeded;
            }
            parent = ancestor[parent_index];
        }
    }
    return .{
        .values = try output.toOwnedSlice(allocator),
        .width = output_schema.columns.len,
    };
}

fn parseConfig(
    allocator: std.mem.Allocator,
    config: []const u8,
) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, config, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
}

const ExpressionContext = struct {
    allocator: std.mem.Allocator,
    row: []const execution.Value,
    output: []const execution.Value = &.{},
    schema: *const plan.Schema,
    state: []const execution.Value = &.{},
    state_names: []const []const u8 = &.{},
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
};

const ExpressionBranch = struct {
    kind: enum { coalesce, if_else, unary, binary, concat },
    op: []const u8,
    count: usize,
    compiled_op: ?CompiledOp = null,
};

const ExpressionInspection = union(enum) {
    value: execution.Value,
    branch: ExpressionBranch,
};

const ExpressionNode = union(enum) {
    compiled: *const CompiledExpr,
    dynamic: std.json.Value,

    fn inspect(self: ExpressionNode, context: ExpressionContext) !ExpressionInspection {
        return switch (self) {
            .dynamic => |value| inspectDynamicExpression(value, context),
            .compiled => |expression| switch (expression.*) {
                .null_value => .{ .value = .null },
                .boolean => |value| .{ .value = .{ .boolean = value } },
                .integer => |value| .{ .value = .{ .integer = value } },
                .float => |value| .{ .value = .{ .float = value } },
                .text => |value| .{ .value = .{
                    .string = try context.allocator.dupe(u8, value),
                } },
                .field => |index| .{ .value = context.row[index] },
                .output_field => |index| .{ .value = context.output[index] },
                .dynamic => |value| inspectDynamicExpression(value, context),
                .is_null => expressionBranch("is-null", 1),
                .not => expressionBranch("not", 1),
                .if_else => expressionBranch("if", 3),
                .coalesce => |children| expressionBranch("coalesce", children.len),
                .binary => |binary| .{ .branch = .{
                    .kind = .binary,
                    .op = compiledOpName(binary.op),
                    .count = 2,
                    .compiled_op = binary.op,
                } },
            },
        };
    }

    fn child(self: ExpressionNode, index: usize) ExpressionNode {
        return switch (self) {
            .dynamic => |value| .{ .dynamic = value.object.get("args").?.array.items[index] },
            .compiled => |expression| switch (expression.*) {
                .dynamic => |value| .{
                    .dynamic = value.object.get("args").?.array.items[index],
                },
                .is_null, .not => |value| .{ .compiled = value },
                .if_else => |value| .{ .compiled = switch (index) {
                    0 => value.condition,
                    1 => value.then_value,
                    2 => value.else_value,
                    else => unreachable,
                } },
                .coalesce => |children| .{ .compiled = children[index] },
                .binary => |value| .{ .compiled = if (index == 0) value.left else value.right },
                else => unreachable,
            },
        };
    }
};

fn compiledOpName(op: CompiledOp) []const u8 {
    return switch (op) {
        .and_op => "and",
        .or_op => "or",
        else => @tagName(op),
    };
}

fn expressionBranch(op: []const u8, count: usize) !ExpressionInspection {
    const kind: @FieldType(ExpressionBranch, "kind") = if (std.mem.eql(u8, op, "coalesce"))
        .coalesce
    else if (std.mem.eql(u8, op, "if"))
        .if_else
    else if (std.mem.eql(u8, op, "concat"))
        .concat
    else if (std.mem.eql(u8, op, "is-null") or std.mem.eql(u8, op, "not") or
        std.mem.eql(u8, op, "parse-time"))
        .unary
    else
        .binary;
    const required: ?usize = switch (kind) {
        .if_else => 3,
        .unary => 1,
        .binary => 2,
        .coalesce, .concat => null,
    };
    if (required) |arity| if (count != arity) return error.InvalidObservationExpressionArity;
    return .{ .branch = .{ .kind = kind, .op = op, .count = count } };
}

fn inspectDynamicExpression(
    expression: std.json.Value,
    context: ExpressionContext,
) !ExpressionInspection {
    return switch (expression) {
        .null => .{ .value = .null },
        .bool => |value| .{ .value = .{ .boolean = value } },
        .integer => |value| .{ .value = .{ .integer = value } },
        .float => |value| .{ .value = .{ .float = value } },
        .number_string => |value| .{ .value = if (std.fmt.parseInt(i64, value, 10)) |integer|
            .{ .integer = integer }
        else |_|
            .{ .float = try std.fmt.parseFloat(f64, value) } },
        .string => |value| .{ .value = .{ .string = try context.allocator.dupe(u8, value) } },
        .array => error.InvalidObservationExpression,
        .object => |object| inspectDynamicObject(object, context),
    };
}

fn inspectDynamicObject(
    object: std.json.ObjectMap,
    context: ExpressionContext,
) !ExpressionInspection {
    if (object.get("field")) |raw| {
        const name = try definition_core.json.string(raw);
        const index = context.schema.find(name) orelse
            return error.UnknownObservationExpressionField;
        return .{ .value = context.row[index] };
    }
    if (object.get("state")) |raw| {
        const name = try definition_core.json.string(raw);
        const index = findName(context.state_names, name) orelse
            return error.UnknownObservationFoldState;
        return .{ .value = context.state[index] };
    }
    if (object.get("param")) |raw| {
        const name = try definition_core.json.string(raw);
        const binding = context.bindings.find(name) orelse return error.UnknownParameter;
        return .{ .value = scalarValue(binding.value) };
    }
    if (object.get("selector")) |raw| {
        return .{ .value = try selectorValue(
            context.selectors,
            try definition_core.json.string(raw),
        ) };
    }
    const op = try definition_core.json.requiredString(object, "op");
    const args = try definition_core.json.array(try definition_core.json.field(object, "args"));
    return expressionBranch(op, args.items.len);
}

const ExpressionFrame = struct {
    node: ExpressionNode,
    branch: ExpressionBranch,
    next: usize = 0,
    left: execution.Value = .null,
    text: std.ArrayList(u8) = .empty,

    fn accept(
        self: *ExpressionFrame,
        value: *execution.Value,
        scratch_allocator: std.mem.Allocator,
        retained_allocator: std.mem.Allocator,
    ) !bool {
        switch (self.branch.kind) {
            .coalesce => {
                if (value.* != .null or self.next + 1 == self.branch.count) return true;
                self.next += 1;
                return false;
            },
            .if_else => {
                if (self.next != 0) return true;
                self.next = if (truthy(value.*)) 1 else 2;
                return false;
            },
            .unary => value.* = unaryExpression(self.branch.op, value.*),
            .binary => {
                if (self.next == 0) {
                    self.left = value.*;
                    self.next = 1;
                    return false;
                }
                value.* = if (self.branch.compiled_op) |op|
                    try compiledBinaryExpression(op, self.left, value.*)
                else
                    try binaryExpression(self.branch.op, self.left, value.*);
            },
            .concat => {
                try self.text.appendSlice(scratch_allocator, valueText(value.*) orelse "");
                self.next += 1;
                if (self.next < self.branch.count) return false;
                value.* = .{ .string = try retained_allocator.dupe(u8, self.text.items) };
            },
        }
        return true;
    }
};

const ExpressionWorkspace = struct {
    allocator: std.mem.Allocator,
    // Every pending expression consumes at least one byte in this bounded config.
    config_bytes: usize,
    frames: std.ArrayList(ExpressionFrame) = .empty,

    fn deinit(self: *ExpressionWorkspace) void {
        std.debug.assert(self.frames.items.len == 0);
        self.frames.deinit(self.allocator);
    }

    fn evaluate(
        self: *ExpressionWorkspace,
        root: ExpressionNode,
        context: ExpressionContext,
    ) !execution.Value {
        std.debug.assert(self.frames.items.len == 0);
        defer {
            for (self.frames.items) |*frame| frame.text.deinit(self.allocator);
            self.frames.clearRetainingCapacity();
        }
        var pending: ?ExpressionNode = root;
        var value: execution.Value = .null;
        while (pending != null or self.frames.items.len > 0) {
            if (pending) |node| {
                pending = null;
                switch (try node.inspect(context)) {
                    .value => |result| value = result,
                    .branch => |branch| {
                        if (branch.count == 0) {
                            value = if (branch.kind == .concat)
                                .{ .string = try context.allocator.alloc(u8, 0) }
                            else
                                .null;
                        } else {
                            if (self.frames.items.len >= self.config_bytes) {
                                return error.InvalidObservationExpression;
                            }
                            try self.frames.append(self.allocator, .{
                                .node = node,
                                .branch = branch,
                            });
                            pending = node.child(0);
                            continue;
                        }
                    },
                }
            }
            if (self.frames.items.len == 0) return value;
            const frame = &self.frames.items[self.frames.items.len - 1];
            if (try frame.accept(&value, self.allocator, context.allocator)) {
                frame.text.deinit(self.allocator);
                _ = self.frames.pop();
            } else {
                std.debug.assert(frame.next < frame.branch.count);
                pending = frame.node.child(frame.next);
            }
        }
        return value;
    }
};

fn unaryExpression(op: []const u8, value: execution.Value) execution.Value {
    if (std.mem.eql(u8, op, "parse-time")) {
        const text = valueText(value) orelse return .null;
        return if (seq_time.parseIsoTimestampMillis(text)) |millis|
            .{ .integer = millis }
        else
            .null;
    }
    return .{ .boolean = if (std.mem.eql(u8, op, "is-null")) value == .null else !truthy(value) };
}

fn binaryExpression(
    op: []const u8,
    left: execution.Value,
    right: execution.Value,
) !execution.Value {
    if (parseCompiledOp(op)) |compiled| return compiledBinaryExpression(compiled, left, right);
    return numericOperator(op, left, right);
}

fn compiledBinaryExpression(
    op: CompiledOp,
    left: execution.Value,
    right: execution.Value,
) !execution.Value {
    return switch (op) {
        .eq => .{ .boolean = valuesEqual(left, right, false) },
        .ne => .{ .boolean = !valuesEqual(left, right, false) },
        .lt => .{ .boolean = compareValues(left, right) == .lt },
        .le => .{ .boolean = compareValues(left, right) != .gt },
        .gt => .{ .boolean = compareValues(left, right) == .gt },
        .ge => .{ .boolean = compareValues(left, right) != .lt },
        .and_op => .{ .boolean = truthy(left) and truthy(right) },
        .or_op => .{ .boolean = truthy(left) or truthy(right) },
        .add, .subtract, .multiply, .divide => numericOperator(@tagName(op), left, right),
    };
}

fn evalExpr(
    workspace: *ExpressionWorkspace,
    allocator: std.mem.Allocator,
    expression: std.json.Value,
    row: []const execution.Value,
    schema: *const plan.Schema,
    state: []const execution.Value,
    state_names: []const []const u8,
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
) !execution.Value {
    return workspace.evaluate(.{ .dynamic = expression }, .{
        .allocator = allocator,
        .row = row,
        .schema = schema,
        .state = state,
        .state_names = state_names,
        .bindings = bindings,
        .selectors = selectors,
    });
}

fn selectorValue(
    selectors: RuntimeSelectors,
    name: []const u8,
) !execution.Value {
    if (std.mem.eql(u8, name, "since")) {
        return if (selectors.since_ms) |value| .{ .integer = value } else .null;
    }
    if (std.mem.eql(u8, name, "until")) {
        return if (selectors.until_ms) |value| .{ .integer = value } else .null;
    }
    const value = if (std.mem.eql(u8, name, "path"))
        selectors.path
    else if (std.mem.eql(u8, name, "root"))
        selectors.root
    else if (std.mem.eql(u8, name, "session-id"))
        selectors.session_id
    else if (std.mem.eql(u8, name, "repo"))
        selectors.repo
    else
        return error.UnknownObservationSelector;
    return if (value) |text| .{ .string = text } else .null;
}

fn numericOperator(
    op: []const u8,
    left: execution.Value,
    right: execution.Value,
) !execution.Value {
    if (left == .null or right == .null) return .null;
    if (left == .integer and right == .integer and !std.mem.eql(u8, op, "divide")) {
        const a = left.integer;
        const b = right.integer;
        return .{ .integer = if (std.mem.eql(u8, op, "add"))
            try std.math.add(i64, a, b)
        else if (std.mem.eql(u8, op, "subtract"))
            try std.math.sub(i64, a, b)
        else if (std.mem.eql(u8, op, "multiply"))
            try std.math.mul(i64, a, b)
        else
            return error.UnsupportedObservationExpression };
    }
    const a = valueFloat(left) orelse return error.ObservationExpressionTypeMismatch;
    const b = valueFloat(right) orelse return error.ObservationExpressionTypeMismatch;
    if (std.mem.eql(u8, op, "divide") and b == 0) return .null;
    return .{ .float = if (std.mem.eql(u8, op, "add"))
        a + b
    else if (std.mem.eql(u8, op, "subtract"))
        a - b
    else if (std.mem.eql(u8, op, "multiply"))
        a * b
    else if (std.mem.eql(u8, op, "divide"))
        a / b
    else
        return error.UnsupportedObservationExpression };
}

fn stringFieldIndices(
    allocator: std.mem.Allocator,
    schema: *const plan.Schema,
    values: std.json.Array,
) ![]u16 {
    const fields = try allocator.alloc(u16, values.items.len);
    errdefer allocator.free(fields);
    for (values.items, 0..) |value, index| {
        fields[index] = schema.find(try definition_core.json.string(value)) orelse
            return error.UnknownObservationField;
    }
    return fields;
}

fn compileDynamicSort(
    allocator: std.mem.Allocator,
    schema: *const plan.Schema,
    values: std.json.Array,
) ![]plan.SortKey {
    const keys = try allocator.alloc(plan.SortKey, values.items.len);
    errdefer allocator.free(keys);
    for (values.items, 0..) |value, index| {
        const object = try definition_core.json.object(value);
        keys[index] = .{
            .field_index = schema.find(
                try definition_core.json.requiredString(object, "field"),
            ) orelse return error.UnknownObservationSortField,
            .direction = if (object.get("direction")) |raw|
                if (std.mem.eql(u8, try definition_core.json.string(raw), "desc"))
                    .descending
                else
                    .ascending
            else
                .ascending,
            .nulls = if (object.get("nulls")) |raw|
                if (std.mem.eql(u8, try definition_core.json.string(raw), "first"))
                    .first
                else
                    .last
            else
                .last,
        };
    }
    return keys;
}

fn findName(names: []const []const u8, wanted: []const u8) ?usize {
    for (names, 0..) |name, index| if (std.mem.eql(u8, name, wanted)) return index;
    return null;
}

fn truthy(value: execution.Value) bool {
    return switch (value) {
        .boolean => |flag| flag,
        .integer => |number| number != 0,
        .float => |number| number != 0,
        .string => |text| text.len != 0,
        .json => |text| text.len != 0,
        .null => false,
    };
}

fn valuesEqual(a: execution.Value, b: execution.Value, ignore_case: bool) bool {
    if (a == .null or b == .null) return a == .null and b == .null;
    if (valueFloat(a)) |left| if (valueFloat(b)) |right| return left == right;
    if (valueText(a)) |left| if (valueText(b)) |right| {
        return if (ignore_case)
            std.ascii.eqlIgnoreCase(left, right)
        else
            std.mem.eql(u8, left, right);
    };
    return switch (a) {
        .boolean => |left| switch (b) {
            .boolean => |right| left == right,
            else => false,
        },
        else => false,
    };
}

fn compareNullable(
    a: execution.Value,
    b: execution.Value,
    nulls: plan.NullOrder,
) std.math.Order {
    if (a == .null and b == .null) return .eq;
    if (a == .null) return if (nulls == .first) .lt else .gt;
    if (b == .null) return if (nulls == .first) .gt else .lt;
    return compareValues(a, b);
}

fn compareValues(a: execution.Value, b: execution.Value) std.math.Order {
    if (valueFloat(a)) |left| if (valueFloat(b)) |right| {
        return std.math.order(left, right);
    };
    if (valueText(a)) |left| if (valueText(b)) |right| {
        return std.mem.order(u8, left, right);
    };
    return switch (a) {
        .boolean => |left| switch (b) {
            .boolean => |right| std.math.order(@intFromBool(left), @intFromBool(right)),
            else => .eq,
        },
        else => .eq,
    };
}

fn valueFloat(value: execution.Value) ?f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => null,
    };
}

fn valueText(value: execution.Value) ?[]const u8 {
    return switch (value) {
        .string, .json => |text| text,
        else => null,
    };
}

test "lineage ownership is strict and does not cross siblings" {
    var graph_columns = [_]plan.Column{
        .{ .name = @constCast("session_id"), .kind = .string, .nullable = false },
        .{ .name = @constCast("parent_session_id"), .kind = .string, .nullable = true },
    };
    var event_columns = [_]plan.Column{
        .{ .name = @constCast("session_id"), .kind = .string, .nullable = false },
    };
    var graph_values = [_]execution.Value{
        .{ .string = "root" },       .null,
        .{ .string = "child-a" },    .{ .string = "root" },
        .{ .string = "child-b" },    .{ .string = "root" },
        .{ .string = "grandchild" }, .{ .string = "child-a" },
    };
    var parsed = try parseConfig(
        std.testing.allocator,
        "{\"left\":\"session_id\",\"right\":\"session_id\"," ++
            "\"node\":\"session_id\",\"parent\":\"parent_sessi" ++
            "on_id\"}",
    );
    defer parsed.deinit();
    var index = try LineageIndex.init(
        std.testing.allocator,
        .{ .values = &graph_values, .width = 2 },
        .{ .columns = &graph_columns },
        try definition_core.json.object(parsed.value),
        .{ .columns = &event_columns },
        .{ .columns = &event_columns },
        8,
    );
    defer index.deinit(std.testing.allocator);
    const child = [_]execution.Value{.{ .string = "child-a" }};
    const sibling = [_]execution.Value{.{ .string = "child-b" }};
    const root = [_]execution.Value{.{ .string = "root" }};
    const grandchild = [_]execution.Value{.{ .string = "grandchild" }};
    try std.testing.expect(try index.matches(&child, &root));
    try std.testing.expect(try index.matches(&grandchild, &root));
    try std.testing.expect(!try index.matches(&child, &sibling));
    try std.testing.expect(!try index.matches(&child, &child));
}

test "join equality hashes null-safe cumulative tuples consistently" {
    var columns = [_]plan.Column{
        .{ .name = @constCast("total"), .kind = .integer, .nullable = true },
        .{ .name = @constCast("cached"), .kind = .integer, .nullable = true },
    };
    var parsed = try parseConfig(
        std.testing.allocator,
        "[{\"left\":\"total\",\"right\":\"total\"},{\"left\":" ++
            "\"cached\",\"right\":\"cached\",\"nulls_equal\":tr" ++
            "ue}]",
    );
    defer parsed.deinit();
    const keys = try definition_core.json.array(parsed.value);
    const row = [_]execution.Value{ .{ .integer = 42 }, .null };
    try std.testing.expectEqual(
        joinEqualityHash(.{ .columns = &columns }, &row, keys, true),
        joinEqualityHash(.{ .columns = &columns }, &row, keys, false),
    );
}

test "streaming lineage lowering is selected from non-token topology" {
    const source =
        \\{
        \\  "schema":"seq-observation-definition/v1",
        \\  "id":"test/message-lineage",
        \\  "requires":{"abi":"seq-observation-abi/v1","operators":["filter","join","scan"]},
        \\  "parameters":{},
        \\  "selectors":[],
        \\  "relations":[
        \\    {"name":"sessions","fields":["session_id","parent_session_id"]},
        \\    {"name":"messages","fields":["session_id","source_event_id","role"]}
        \\  ],
        \\  "inputs":[],
        \\  "pipeline":[
        \\    {"op":"scan","relation":"sessions","as":"session_rows"},
        \\    {"op":"scan","relation":"messages","as":"message_rows"},
        \\    {"op":"filter","input":"message_rows","as":"assistant_rows","where":[{"field":"role","op":"exact","value":"assistant"}]},
        \\    {"op":"join","inputs":["assistant_rows","assistant_rows","session_rows"],"as":"owned_rows",
        \\      "on":{"kind":"anti","keys":[{"left":"source_event_id","right":"source_event_id"}],
        \\        "lineage":{"left":"session_id","right":"session_id","node":"session_id","parent":"parent_session_id"}},
        \\      "fields":[
        \\        {"source":0,"field":"session_id","name":"session_id","type":"string","nullable":false},
        \\        {"source":0,"field":"source_event_id","name":"source_event_id","type":"string","nullable":false},
        \\        {"source":0,"field":"role","name":"role","type":"string","nullable":true}
        \\      ]}
        \\  ],
        \\  "projections":{"rows":{"relation":"owned_rows","schema":"test/message-lineage/v1","fields":["session_id","source_event_id","role"],"renderers":["json"]}},
        \\  "bounds":{"max_rows":100,"max_output_bytes":4096,"max_fold_states":4,"max_input_bytes":1048576,"max_graph_depth":8,"max_graph_nodes":100,"max_diagnostics":8}
        \\}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "definition.json", .data = source });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "definition.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "definition.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var native_plan = try plan.compile(std.testing.allocator, &definition_plan);
    defer native_plan.deinit(std.testing.allocator);
    const schedule = (try streamingLineagePlan(
        std.testing.allocator,
        &definition_plan,
        &native_plan,
        "rows",
    )).?;
    try std.testing.expect(native_plan.stages[schedule.scan_stage].operation == .scan);
    try std.testing.expectEqual(
        @import("physical.zig").Relation.messages,
        native_plan.stages[schedule.scan_stage].operation.scan.relation,
    );
    try std.testing.expectEqualStrings(
        "assistant_rows",
        native_plan.stages[schedule.local_stage].name,
    );
}

const expression_test_bindings: definition_core.parameters.Bindings = .{
    .items = &.{},
    .values_digest = .{0} ** 71,
};
const expression_test_schema: plan.Schema = .{ .columns = &.{} };

fn testExpressionValue(
    allocator: std.mem.Allocator,
    source: []const u8,
    compiled: bool,
) !execution.Value {
    var parsed = try parseConfig(allocator, source);
    defer parsed.deinit();
    var workspace: ExpressionWorkspace = .{ .allocator = allocator, .config_bytes = source.len };
    defer workspace.deinit();
    const node: ExpressionNode = if (compiled)
        .{ .compiled = try compileExpr(allocator, parsed.value, &expression_test_schema, null, 0) }
    else
        .{ .dynamic = parsed.value };
    return workspace.evaluate(node, .{
        .allocator = allocator,
        .row = &.{},
        .schema = &expression_test_schema,
        .bindings = &expression_test_bindings,
        .selectors = .{},
    });
}

test "compiled and dynamic expressions preserve lazy and eager branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { source: []const u8, expected: execution.Value }{
        .{ .source = "{\"op\":\"if\",\"args\":[true,7,{\"op\":\"unknown\"," ++
            "\"args\":[1,2]}]}", .expected = .{ .integer = 7 } },
        .{ .source = "{\"op\":\"coalesce\",\"args\":[null,9,{\"op\":\"unk" ++
            "nown\",\"args\":[1,2]}]}", .expected = .{ .integer = 9 } },
        .{ .source = "{\"op\":\"unknown\",\"args\":[null,2]}", .expected = .null },
        .{ .source = "{\"op\":\"concat\",\"args\":[\"a\",{\"op\":\"concat\"," ++
            "\"args\":[\"b\",\"c\"]}]}", .expected = .{ .string = "abc" } },
    };
    for (cases) |case| for ([_]bool{ false, true }) |compiled| {
        const actual = try testExpressionValue(arena.allocator(), case.source, compiled);
        try std.testing.expect(valuesEqual(case.expected, actual, false));
    };
    for ([_]bool{ false, true }) |compiled| {
        try std.testing.expectError(error.UnsupportedObservationExpression, testExpressionValue(
            arena.allocator(),
            "{\"op\":\"and\",\"args\":[false,{\"op\":\"unknown\",\"args\":[1,2]}]}",
            compiled,
        ));
    }
}

test "compiled field validation remains eager before row execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "{\"op\":\"if\",\"args\":[true,7,{\"field\":\"missing\"}]}";
    try std.testing.expectError(
        error.UnknownObservationExpressionField,
        testExpressionValue(arena.allocator(), source, true),
    );
    const actual = try testExpressionValue(arena.allocator(), source, false);
    try std.testing.expectEqual(7, actual.integer);
}

test "deep expressions compile and evaluate with explicit frames" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..8192) |_| try source.appendSlice(std.testing.allocator, "{\"op\":\"not\",\"args\":[");
    try source.appendSlice(std.testing.allocator, "true");
    for (0..8192) |_| try source.appendSlice(std.testing.allocator, "]}");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |compiled| {
        const value = try testExpressionValue(arena.allocator(), source.items, compiled);
        try std.testing.expect(value.boolean);
    }
}

fn exerciseExpressionAllocationFailures(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const source = "{\"op\":\"if\",\"args\":[true,{\"op\":\"concat\",\"args\":[\"a\"," ++
        "{\"op\":\"if\",\"args\":[true,\"b\",\"c\"]}]},\"unused\"]}";
    var parsed = try parseConfig(allocator, source);
    defer parsed.deinit();
    var workspace: ExpressionWorkspace = .{ .allocator = allocator, .config_bytes = source.len };
    defer workspace.deinit();
    const compiled = try compileExpr(
        arena.allocator(),
        parsed.value,
        &expression_test_schema,
        null,
        0,
    );
    const value = try workspace.evaluate(.{ .compiled = compiled }, .{
        .allocator = arena.allocator(),
        .row = &.{},
        .schema = &expression_test_schema,
        .bindings = &expression_test_bindings,
        .selectors = .{},
    });
    try std.testing.expectEqualStrings("ab", value.string);
}

test "expression workspace releases active frames at each allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExpressionAllocationFailures,
        .{},
    );
}

const graph_test_columns = [_]plan.Column{
    .{ .name = @constCast("value"), .kind = .integer, .nullable = false },
};
const graph_test_fields = [_]u16{0};
const graph_test_sort = [_]plan.SortKey{
    .{ .field_index = 0, .direction = .ascending, .nulls = .last },
};
const graph_test_stages = [_]plan.Stage{
    .{
        .name = @constCast("source"),
        .source = null,
        .schema = .{
            .columns = @constCast(&graph_test_columns),
        },
        .operation = .{
            .scan = .{
                .relation = .sessions,
                .field_indices = @constCast(&graph_test_fields),
            },
        },
    },
    .{
        .name = @constCast("copy"),
        .source = .{
            .stage = 0,
        },
        .schema = .{
            .columns = @constCast(&graph_test_columns),
        },
        .operation = .alias,
    },
    .{
        .name = @constCast("ranked"),
        .source = .{
            .stage = 1,
        },
        .schema = .{
            .columns = @constCast(&graph_test_columns),
        },
        .operation = .{
            .top_k = .{
                .keys = @constCast(&graph_test_sort),
                .limit = .{
                    .fixed = 1,
                },
            },
        },
    },
};
const graph_test_steps = [_]definition.Step{
    .{
        .operator = .scan,
        .output_name = @constCast("source"),
        .input_names = &.{},
        .canonical_config = @constCast("{}"),
    },
    .{
        .operator = .named_relation,
        .output_name = @constCast("copy"),
        .input_names = @constCast(&[_][]u8{@constCast("source")}),
        .canonical_config = @constCast("{}"),
    },
    .{
        .operator = .top_k,
        .output_name = @constCast("ranked"),
        .input_names = @constCast(&[_][]u8{@constCast("copy")}),
        .canonical_config = @constCast("{}"),
    },
};
const graph_test_projection = [_]definition.Projection{
    .{
        .name = @constCast("rows"),
        .relation = @constCast("ranked"),
        .schema_id = @constCast("test/rows"),
        .fields = &.{},
        .renderer_mask = 1,
    },
};
const graph_test_definition: definition.Plan = .{
    .id = @constCast("test/graph"),
    .closure_digest = .{0} ** 71,
    .operator_mask = 0,
    .parameter_declarations = .{
        .items = &.{},
        .shape_digest = .{0} ** 71,
    },
    .selector_mask = 0,
    .relations = &.{},
    .inputs = &.{},
    .steps = @constCast(&graph_test_steps),
    .projections = @constCast(&graph_test_projection),
    .bounds = .{
        .max_rows = 3,
        .max_output_bytes = 4096,
        .max_fold_states = 1,
        .max_input_bytes = 4096,
        .max_graph_depth = 2,
        .max_graph_nodes = 3,
        .max_diagnostics = 1,
    },
};
const graph_test_native: plan.Plan = .{
    .stages = @constCast(&graph_test_stages),
    .projections = @constCast(&[_]plan.Projection{
        .{
            .definition_index = 0,
            .stage_index = 2,
            .field_indices = @constCast(&graph_test_fields),
        },
    }),
    .max_rows = 3,
    .max_output_bytes = 4096,
};

fn exerciseGraphAllocationFailures(allocator: std.mem.Allocator, max_rows: usize) !void {
    const source = [_]execution.Value{ .{ .integer = 3 }, .{ .integer = 1 }, .{ .integer = 2 } };
    const owned = try allocator.dupe(execution.Value, &source);
    var scans = [_]ScanInput{
        .{ .stage_index = 0, .table = .{ .values = owned, .width = 1 }, .owned = true },
    };
    defer if (scans[0].owned) allocator.free(owned);
    var definition_plan = graph_test_definition;
    definition_plan.bounds.max_rows = max_rows;
    const result = execute(
        allocator,
        allocator,
        &definition_plan,
        &graph_test_native,
        &expression_test_bindings,
        .{},
        "rows",
        &scans,
    ) catch |err| {
        if (err != error.ObservationRowBoundExceeded or max_rows >= 3) return err;
        try std.testing.expect(!scans[0].owned);
        return;
    };
    defer allocator.free(result.table.values);
    try std.testing.expectEqual(3, max_rows);
    try std.testing.expectEqual(1, result.table.values.len);
    try std.testing.expectEqual(1, result.table.values[0].integer);
    try std.testing.expectEqual(3, result.source_rows);
    try std.testing.expectEqual(7, result.materialized_rows);
    try std.testing.expect(!scans[0].owned);
}

test "graph ownership cleans up sorted intermediates and every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseGraphAllocationFailures,
        .{@as(usize, 3)},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseGraphAllocationFailures,
        .{@as(usize, 2)},
    );
}

test "target graph output survives shared execution scratch teardown" {
    var source = [_]execution.Value{ .{ .integer = 3 }, .{ .integer = 1 }, .{ .integer = 2 } };
    var scans = [_]ScanInput{
        .{ .stage_index = 0, .table = .{ .values = &source, .width = 1 } },
    };
    const result = try executeTarget(
        std.testing.allocator,
        std.testing.allocator,
        &graph_test_definition,
        &graph_test_native,
        &expression_test_bindings,
        .{},
        2,
        &scans,
    );
    defer std.testing.allocator.free(result.table.values);
    try std.testing.expectEqual(1, result.table.values.len);
    try std.testing.expectEqual(1, result.table.values[0].integer);
    try std.testing.expectEqual(3, source[0].integer);
    try std.testing.expectEqual(3, result.source_rows);
    try std.testing.expectEqual(7, result.materialized_rows);
}

test "stage traversal checks depth before memoization and respects scan boundaries" {
    var definition_plan = graph_test_definition;
    definition_plan.bounds.max_graph_depth = 1;
    var reachable = [_]bool{ true, false, false };
    try std.testing.expectError(error.ObservationGraphDepthExceeded, markReachable(
        std.testing.allocator,
        &definition_plan,
        &graph_test_native,
        2,
        &reachable,
        &.{},
        0,
    ));
    @memset(&reachable, false);
    definition_plan.bounds.max_graph_depth = 2;
    try markReachable(
        std.testing.allocator,
        &definition_plan,
        &graph_test_native,
        2,
        &reachable,
        &.{},
        0,
    );
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, &reachable);
    @memset(&reachable, false);
    definition_plan.bounds.max_graph_depth = 1;
    var scans = [_]ScanInput{
        .{ .stage_index = 1, .table = .{ .values = &.{}, .width = 1 } },
    };
    try markReachable(
        std.testing.allocator,
        &definition_plan,
        &graph_test_native,
        2,
        &reachable,
        &scans,
        0,
    );
    try std.testing.expectEqualSlices(bool, &.{ false, true, true }, &reachable);
}
