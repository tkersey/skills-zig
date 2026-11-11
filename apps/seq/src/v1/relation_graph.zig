const std = @import("std");
const core_selection = @import("core_selection");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const execution = @import("execution.zig");
const plan = @import("plan.zig");
const expressions = @import("expressions.zig");
pub const RuntimeSelectors = expressions.RuntimeSelectors;
const ExpressionWorkspace = expressions.ExpressionWorkspace;
const ExpressionNode = expressions.ExpressionNode;
const compileExpr = expressions.compileExpr;
const evalExpr = expressions.evalExpr;
const parseConfig = expressions.parseConfig;
const scalarValue = expressions.scalarValue;
const findName = expressions.findName;
const truthy = expressions.truthy;
const value_module = @import("value.zig");
const valuesEqual = value_module.equal;
const valueFloat = expressions.valueFloat;
const valueText = expressions.valueText;

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

pub const PartitionOrder = union(enum) {
    path,
    session: plan.SortKey,
};

pub const StreamingLineagePlan = struct {
    scan_stage: u16,
    local_stage: u16,
    lineage_stage: u16,
    graph_stage: u16,
    seed_stage: u16,
    partition_order: PartitionOrder,
};

pub fn boundedNativePrefix(
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    projection_name: []const u8,
) !?u16 {
    const projection = findProjection(definition_plan, projection_name) orelse
        return error.UnknownObservationProjection;
    var current = native_plan.projections[projection].stage_index;
    var target: ?u16 = null;
    var depth: usize = 0;
    while (depth < 256 and depth <= definition_plan.bounds.max_graph_depth) : (depth += 1) {
        const stage = &native_plan.stages[current];
        switch (stage.operation) {
            .scan => |scan| return if (scan.relation == .sessions) null else target,
            .filter, .project, .alias, .limit => {},
            .top_k => target = current,
            .generic => |generic| if (generic.operator != .derive) return null,
            else => return null,
        }
        if (definition_plan.steps[current].input_names.len != 1) return null;
        current = switch (stage.source orelse return null) {
            .stage => |index| index,
            .external => return null,
        };
    }
    return error.ObservationPipelineTooDeep;
}

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
    try requireValidJoins(allocator, definition_plan, native_plan, reachable);
    for (native_plan.stages, 0..) |stage, stage_index| {
        if (!reachable[stage_index] or stage.operation != .generic) continue;
        const generic = stage.operation.generic;
        if (generic.operator != .join) continue;
        var spec = try compileJoin(
            allocator,
            native_plan,
            definition_plan.steps[stage_index],
            generic.canonical_config,
        );
        defer spec.deinit(allocator);
        const lineage = spec.lineage orelse continue;
        if (!streamableLineageJoin(native_plan, &spec)) return null;
        if (!try carriesSessionColumns(allocator, native_plan, lineage.graph_stage)) return null;
        const scan_stage = try streamablePartitionRoot(
            allocator,
            definition_plan,
            native_plan,
            spec.left_stage,
        ) orelse return null;
        const seed_stage = try streamingSeedScan(
            allocator,
            definition_plan,
            native_plan,
            native_plan.projections[projection_index].stage_index,
            @intCast(stage_index),
            lineage.graph_stage,
        ) orelse return null;
        return .{
            .scan_stage = scan_stage,
            .local_stage = spec.left_stage,
            .lineage_stage = @intCast(stage_index),
            .graph_stage = lineage.graph_stage,
            .seed_stage = seed_stage,
            .partition_order = try localPartitionOrder(
                allocator,
                definition_plan,
                native_plan,
                spec.left_stage,
            ),
        };
    }
    return null;
}

pub fn requireBoundParameters(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    bindings: *const definition_core.parameters.Bindings,
    projection_name: []const u8,
) !void {
    const reachable = try reachableStages(allocator, definition_plan, native_plan, projection_name);
    defer allocator.free(reachable);
    for (native_plan.stages, reachable) |stage, is_reachable| {
        if (!is_reachable) continue;
        switch (stage.operation) {
            .filter => |filter| for (filter.predicates) |predicate| switch (predicate.operand) {
                .parameter => |index| try requireBinding(definition_plan, bindings, index),
                .constant => {},
            },
            .limit => |limit| try requireLimitBinding(definition_plan, bindings, limit),
            .top_k => |top_k| try requireLimitBinding(definition_plan, bindings, top_k.limit),
            else => {},
        }
    }
}

fn requireLimitBinding(
    definition_plan: *const definition.Plan,
    bindings: *const definition_core.parameters.Bindings,
    limit: plan.Limit,
) !void {
    switch (limit) {
        .parameter => |index| try requireBinding(definition_plan, bindings, index),
        .fixed => {},
    }
}

fn requireBinding(
    definition_plan: *const definition.Plan,
    bindings: *const definition_core.parameters.Bindings,
    index: u16,
) !void {
    const name = definition_plan.parameter_declarations.items[index].name;
    if (bindings.find(name) == null) return error.MissingObservationParameter;
}

fn carriesSessionColumns(
    allocator: std.mem.Allocator,
    native_plan: *const plan.Plan,
    graph_stage: u16,
) !bool {
    var current = graph_stage;
    for (0..native_plan.stages.len) |_| {
        const stage = native_plan.stages[current];
        if (readsParsedSessionColumn(native_plan, stage)) return false;
        switch (stage.operation) {
            .scan => return true,
            .filter, .project, .alias, .sort => {},
            .generic => |generic| {
                if (generic.operator != .derive) return false;
                if (!try derivePreservesSessionColumns(allocator, generic.canonical_config)) {
                    return false;
                }
            },
            .limit, .top_k, .distinct, .aggregate => return false,
        }
        current = switch (stage.source orelse return false) {
            .stage => |index| index,
            .external => return false,
        };
    }
    return false;
}

fn readsParsedSessionColumn(native_plan: *const plan.Plan, stage: plan.Stage) bool {
    const name = "token_usage_observation_count";
    const input = switch (stage.source orelse return false) {
        .stage => |index| native_plan.stages[index],
        .external => return false,
    };
    const column = input.schema.find(name) orelse return false;
    return switch (stage.operation) {
        .filter => |filter| for (filter.predicates) |predicate| {
            if (predicate.field_index == column) break true;
        } else false,
        .generic => |generic| std.mem.indexOf(
            u8,
            generic.canonical_config,
            "\"" ++ name ++ "\"",
        ) != null,
        else => false,
    };
}

fn derivePreservesSessionColumns(allocator: std.mem.Allocator, config: []const u8) !bool {
    var parsed = try parseConfig(allocator, config);
    defer parsed.deinit();
    const root = try definition_core.json.object(parsed.value);
    if (root.get("preserve_input")) |raw| {
        if (!try definition_core.json.boolean(raw)) return false;
    }
    const fields = try definition_core.json.array(try definition_core.json.field(root, "fields"));
    for (fields.items) |item| {
        const field = try definition_core.json.object(item);
        const name = try definition_core.json.requiredString(field, "name");
        if (std.mem.eql(u8, name, "session_id") or std.mem.eql(u8, name, "parent_session_id")) {
            return false;
        }
    }
    return true;
}

fn seedsSessionFields(field_indices: []const u16) bool {
    const seeded = [_][]const u8{
        "session_id",
        "path",
        "parent_session_id",
        "control_parent_session_id",
        "forked_from_session_id",
        "parent_relation",
        "lineage_conflict",
        "subagent_history_start_ordinal",
        "token_usage_observation_count",
    };
    for (field_indices) |field_index| {
        const name = @import("physical.zig").Relation.sessions.fields()[field_index].name;
        for (seeded) |candidate| {
            if (std.mem.eql(u8, name, candidate)) break;
        } else return false;
    }
    return true;
}

fn requireValidJoins(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    reachable: []const bool,
) !void {
    for (native_plan.stages, reachable, 0..) |stage, reached, stage_index| {
        if (!reached or stage.operation != .generic) continue;
        if (stage.operation.generic.operator != .join) continue;
        var spec = try compileJoin(
            allocator,
            native_plan,
            definition_plan.steps[stage_index],
            stage.operation.generic.canonical_config,
        );
        spec.deinit(allocator);
    }
}

fn streamableLineageJoin(native_plan: *const plan.Plan, spec: *const JoinSpec) bool {
    const lineage = spec.lineage orelse return false;
    if (spec.kind != .anti or spec.left_stage != spec.right_stage) return false;
    for (spec.keys) |key| {
        if (key.comparison != .eq or key.left != key.right) return false;
    }
    const local = native_plan.stages[spec.left_stage].schema;
    const graph = native_plan.stages[lineage.graph_stage].schema;
    return columnNamed(local, lineage.left, "session_id") and
        columnNamed(local, lineage.right, "session_id") and
        columnNamed(graph, lineage.node, "session_id") and
        columnNamed(graph, lineage.parent, "parent_session_id");
}

fn columnNamed(schema: plan.Schema, column: u16, name: []const u8) bool {
    return std.mem.eql(u8, schema.columns[column].name, name);
}

fn streamablePartitionRoot(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    local_stage: u16,
) !?u16 {
    const root = partitionScanRoot(allocator, definition_plan, native_plan, local_stage);
    return root catch |err| switch (err) {
        error.ObservationPartitionOperatorUnsupported,
        error.ObservationPartitionLayoutMissing,
        error.ObservationPartitionPrefixHasMultipleScans,
        => return null,
        else => return err,
    };
}

fn streamingSeedScan(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    projection_stage: u16,
    lineage_stage: u16,
    graph_stage: u16,
) !?u16 {
    const count = native_plan.stages.len;
    const graph_reachable = try allocator.alloc(bool, count);
    defer allocator.free(graph_reachable);
    @memset(graph_reachable, false);
    try markReachable(
        allocator,
        definition_plan,
        native_plan,
        graph_stage,
        graph_reachable,
        &.{},
        0,
    );
    var seeded_scan: ?u16 = null;
    for (native_plan.stages, graph_reachable, 0..) |stage, reached, index| {
        if (!reached or stage.operation != .scan) continue;
        if (seeded_scan != null or stage.operation.scan.relation != .sessions) return null;
        if (!seedsSessionFields(stage.operation.scan.field_indices)) return null;
        seeded_scan = @intCast(index);
    }
    const seed = seeded_scan orelse return null;
    var boundary = [_]ScanInput{.{
        .stage_index = lineage_stage,
        .table = .{ .values = &.{}, .width = 0 },
    }};
    const reachable = try allocator.alloc(bool, count);
    defer allocator.free(reachable);
    @memset(reachable, false);
    try markReachable(
        allocator,
        definition_plan,
        native_plan,
        projection_stage,
        reachable,
        &boundary,
        0,
    );
    for (native_plan.stages, reachable, 0..) |stage, reached, index| {
        if (reached and stage.operation == .scan and index != seed) return null;
    }
    return seed;
}

pub fn projectionMayTruncate(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    projection_name: []const u8,
) !bool {
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
    for (native_plan.stages, reachable) |stage, reached| {
        if (!reached) continue;
        switch (stage.operation) {
            .limit, .top_k => return true,
            else => {},
        }
    }
    return false;
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
) !u16 {
    const visited = try allocator.alloc(bool, native_plan.stages.len);
    defer allocator.free(visited);
    @memset(visited, false);
    var pending: std.ArrayList(u16) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, stage_index);
    var root: ?u16 = null;
    while (pending.pop()) |current| {
        if (visited[current]) continue;
        visited[current] = true;
        const stage = native_plan.stages[current];
        if (stage.operation == .scan) {
            try validatePartitionScan(stage, current, root);
            root = current;
            continue;
        }
        try validatePartitionOperator(allocator, definition_plan, native_plan, current);
        const inputs = definition_plan.steps[current].input_names;
        if (inputs.len == 0) return error.ObservationPartitionLayoutMissing;
        var index = inputs.len;
        while (index > 0) {
            index -= 1;
            const input = native_plan.findStage(inputs[index]) orelse
                return error.ObservationExternalGraphInputUnsupported;
            if (!visited[input]) try pending.append(allocator, input);
        }
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

fn validatePartitionOperator(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    stage_index: u16,
) !void {
    const stage = native_plan.stages[stage_index];
    const local = switch (stage.operation) {
        .filter, .project, .alias => true,
        .distinct => |distinct| keysSession(native_plan, stage, distinct.field_indices),
        .generic => |generic| switch (generic.operator) {
            .derive => try copiesSessionOutputs(allocator, generic.canonical_config, "fields"),
            .join => try joinsSessionLocally(allocator, definition_plan, native_plan, stage_index),
            .ordered_fold => try sessionFoldOrder(
                allocator,
                definition_plan,
                native_plan,
                stage_index,
            ) != null,
            else => false,
        },
        else => false,
    };
    if (!local) return error.ObservationPartitionOperatorUnsupported;
}

fn keysSession(native_plan: *const plan.Plan, stage: plan.Stage, field_indices: []const u16) bool {
    const input = switch (stage.source orelse return false) {
        .stage => |index| native_plan.stages[index],
        .external => return false,
    };
    const column = input.schema.find("session_id") orelse return false;
    return std.mem.indexOfScalar(u16, field_indices, column) != null;
}

fn copiesSessionOutputs(
    allocator: std.mem.Allocator,
    config: []const u8,
    outputs: []const u8,
) !bool {
    var parsed = try parseConfig(allocator, config);
    defer parsed.deinit();
    const root = try definition_core.json.object(parsed.value);
    return copiesSessionFields(try configArray(root, outputs));
}

fn copiesSessionFields(outputs: std.json.Array) !bool {
    for (outputs.items) |item| {
        const field = try definition_core.json.object(item);
        const name = try definition_core.json.requiredString(field, "name");
        if (!std.mem.eql(u8, name, "session_id")) continue;
        if (!copiesSessionExpression(try definition_core.json.field(field, "expr"))) return false;
    }
    return true;
}

fn sessionFoldOrder(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    stage_index: u16,
) !?plan.SortKey {
    const inputs = definition_plan.steps[stage_index].input_names;
    if (inputs.len != 1) return null;
    const input = native_plan.findStage(inputs[0]) orelse return null;
    const schema = &native_plan.stages[input].schema;
    const config = native_plan.stages[stage_index].operation.generic.canonical_config;
    var parsed = try parseConfig(allocator, config);
    defer parsed.deinit();
    const root = try definition_core.json.object(parsed.value);
    if (!try copiesSessionFields(try configArray(root, "emit"))) return null;
    const session = schema.find("session_id") orelse return null;
    const keys = try stringFieldIndices(allocator, schema, try configArray(root, "keys"));
    defer allocator.free(keys);
    if (std.mem.indexOfScalar(u16, keys, session) == null) return null;
    const order = try compileDynamicSort(allocator, schema, try configArray(root, "order_by"));
    defer allocator.free(order);
    if (order.len == 0 or order[0].field_index != session) return null;
    return order[0];
}

fn localPartitionOrder(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    local_stage: u16,
) !PartitionOrder {
    var current = local_stage;
    for (0..native_plan.stages.len) |_| {
        const stage = native_plan.stages[current];
        switch (stage.operation) {
            .scan => return .path,
            .generic => |generic| if (generic.operator == .ordered_fold) {
                const key = try sessionFoldOrder(allocator, definition_plan, native_plan, current);
                return .{ .session = key.? };
            },
            else => {},
        }
        const inputs = definition_plan.steps[current].input_names;
        current = native_plan.findStage(inputs[0]) orelse
            return error.ObservationExternalGraphInputUnsupported;
    }
    unreachable;
}

pub fn rankPartitions(
    allocator: std.mem.Allocator,
    order: PartitionOrder,
    sessions: []const ?[]const u8,
) ![]usize {
    const ranks = try allocator.alloc(usize, sessions.len);
    errdefer allocator.free(ranks);
    for (ranks, 0..) |*rank, index| rank.* = index;
    const key = switch (order) {
        .path => return ranks,
        .session => |value| value,
    };
    const partitions = try allocator.alloc(usize, sessions.len);
    defer allocator.free(partitions);
    for (partitions, 0..) |*partition, index| partition.* = index;
    const context: PartitionContext = .{ .key = key, .sessions = sessions };
    std.mem.sort(usize, partitions, context, PartitionContext.lessThan);
    for (partitions, 0..) |partition, rank| ranks[partition] = rank;
    return ranks;
}

const PartitionContext = struct {
    key: plan.SortKey,
    sessions: []const ?[]const u8,

    fn lessThan(context: PartitionContext, left: usize, right: usize) bool {
        const compared = sortKeyOrder(
            context.key,
            sessionValue(context.sessions[left]),
            sessionValue(context.sessions[right]),
        );
        if (compared != .eq) return compared == .lt;
        return left < right;
    }

    fn sessionValue(session: ?[]const u8) execution.Value {
        return if (session) |text| .{ .string = text } else .null;
    }
};

fn copiesSessionExpression(raw: std.json.Value) bool {
    const expr = switch (raw) {
        .object => |object| object,
        else => return false,
    };
    if (expr.count() != 1) return false;
    const copied = expr.get("field") orelse return false;
    return copied == .string and std.mem.eql(u8, copied.string, "session_id");
}

fn joinsSessionLocally(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    stage_index: u16,
) !bool {
    const stage = native_plan.stages[stage_index];
    var spec = try compileJoin(
        allocator,
        native_plan,
        definition_plan.steps[stage_index],
        stage.operation.generic.canonical_config,
    );
    defer spec.deinit(allocator);
    const left_session = native_plan.stages[spec.left_stage].schema.find("session_id") orelse
        return false;
    const right_session = native_plan.stages[spec.right_stage].schema.find("session_id") orelse
        return false;
    const paired = for (spec.keys) |key| {
        const session_pair = key.left == left_session and key.right == right_session;
        if (key.comparison == .eq and session_pair) break true;
    } else false;
    if (!paired) return false;
    for (spec.outputs, stage.schema.columns) |output, column| {
        if (!std.mem.eql(u8, column.name, "session_id")) continue;
        if (output.side != .left or output.column != left_session) return false;
    }
    return true;
}

pub fn requiredScanStages(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    projection_name: []const u8,
) ![]u16 {
    const reachable = try reachableStages(allocator, definition_plan, native_plan, projection_name);
    defer allocator.free(reachable);
    var scans: std.ArrayList(u16) = .empty;
    errdefer scans.deinit(allocator);
    for (native_plan.stages, 0..) |stage, index| {
        if (reachable[index] and stage.operation == .scan) {
            try scans.append(allocator, @intCast(index));
        }
    }
    return scans.toOwnedSlice(allocator);
}

pub fn selectsPhysically(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    projection_name: []const u8,
) !bool {
    const reachable = try reachableStages(allocator, definition_plan, native_plan, projection_name);
    defer allocator.free(reachable);
    var scans: usize = 0;
    for (native_plan.stages, reachable) |stage, is_reachable| {
        if (!is_reachable) continue;
        switch (stage.operation) {
            .scan => scans += 1,
            .generic => |generic| switch (generic.operator) {
                .reachability => return false,
                .join => if (try joinsLineage(allocator, generic.canonical_config)) return false,
                else => {},
            },
            else => {},
        }
    }
    return scans == 1;
}

pub fn reachesLineageJoin(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    projection_name: []const u8,
) !bool {
    const reachable = try reachableStages(allocator, definition_plan, native_plan, projection_name);
    defer allocator.free(reachable);
    for (native_plan.stages, reachable) |stage, is_reachable| {
        if (!is_reachable or stage.operation != .generic) continue;
        const generic = stage.operation.generic;
        if (generic.operator != .join) continue;
        if (try joinsLineage(allocator, generic.canonical_config)) return true;
    }
    return false;
}

fn joinsLineage(allocator: std.mem.Allocator, config: []const u8) !bool {
    var parsed = try parseConfig(allocator, config);
    defer parsed.deinit();
    const root = try definition_core.json.object(parsed.value);
    const on = try definition_core.json.object(try definition_core.json.field(root, "on"));
    return on.get("lineage") != null;
}

fn reachableStages(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    projection_name: []const u8,
) ![]bool {
    const projection_index = findProjection(definition_plan, projection_name) orelse
        return error.UnknownObservationProjection;
    const reachable = try allocator.alloc(bool, native_plan.stages.len);
    errdefer allocator.free(reachable);
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
    return reachable;
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
            const stage = self.native_plan.stages[index];
            if (stage.operation == .scan) return error.ObservationInputNotExecuted;
            const first_index = self.native_plan.findStage(step.input_names[0]) orelse
                return error.ObservationExternalGraphInputUnsupported;
            const input = self.tables[first_index] orelse return error.ObservationInputNotExecuted;
            const exclusive = self.owned[first_index] and self.consumers[first_index] == 1;
            const copy_input = !exclusive and switch (stage.operation) {
                .filter => true,
                .generic => |generic| generic.operator == .ordered_fold,
                else => false,
            };
            const working = if (copy_input) try copyTable(self.allocator, input) else input;
            var copy_adopted = false;
            defer if (copy_input and !copy_adopted) self.allocator.free(working.values);
            const value = try executeStage(
                self.allocator,
                self.retained_allocator,
                self.definition_plan,
                self.native_plan,
                self.bindings,
                self.selectors,
                stage,
                step,
                self.tables,
                working,
                exclusive,
            );
            if (copy_input and value.values.ptr == working.values.ptr) {
                self.owned[index] = true;
                self.allocations[index] = working.values;
                copy_adopted = true;
            } else self.adoptTable(index, step, value);
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
            const allocation = self.allocations[input] orelse continue;
            if (allocation.len == 0) continue;
            std.debug.assert(self.owned[input] and self.consumers[input] == 1);
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
    input: Table,
    input_is_exclusive: bool,
) !Table {
    const first_index = native_plan.findStage(step.input_names[0]) orelse
        return error.ObservationExternalGraphInputUnsupported;
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
            input_is_exclusive,
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
    const rows = try input.rowCount();
    const count = @min(rows, try limitCount(definition_plan, bindings, top_k.limit));
    if (count > rows / 2 or !hasTotalSortOrder(input, top_k.keys)) {
        return sortTablePrefix(allocator, input, .{ .keys = top_k.keys }, count);
    }
    const indices = try allocator.alloc(usize, count);
    defer allocator.free(indices);
    const context = SortContext{ .table = input, .keys = top_k.keys };
    for (indices, 0..) |*slot, index| {
        slot.* = index;
        core_selection.siftUp(usize, indices[0 .. index + 1], context, SortContext.lessThan);
    }
    if (count != 0) for (count..rows) |index| {
        if (!SortContext.lessThan(context, index, indices[0])) continue;
        indices[0] = index;
        core_selection.siftDown(usize, indices, context, SortContext.lessThan);
    };
    std.sort.heap(usize, indices, context, SortContext.lessThan);
    return copyIndexedRows(allocator, input, indices);
}

fn hasTotalSortOrder(input: Table, keys: []const plan.SortKey) bool {
    const Family = enum { number, text, boolean };
    for (keys) |key| {
        var family: ?Family = null;
        for (0..input.values.len / input.width) |index| {
            const value = input.row(index)[key.field_index];
            const current: Family = switch (value) {
                .integer => .number,
                .float => |number| if (std.math.isFinite(number)) .number else return false,
                .string, .json => .text,
                .boolean => .boolean,
                .null => continue,
            };
            if (family) |expected| if (current != expected) return false;
            family = current;
        }
    }
    return true;
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
    input_is_exclusive: bool,
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
            input_is_exclusive,
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
            (bindings.find(definition_plan.parameter_declarations.items[index].name) orelse
                return error.MissingObservationParameter).value,
        ),
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
        .less_than => value_module.holds(left, right, .lt),
        .less_or_equal => value_module.holds(left, right, .le),
        .greater_than => value_module.holds(left, right, .gt),
        .greater_or_equal => value_module.holds(left, right, .ge),
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
        .contains => std.ascii.findIgnoreCase(a, b) != null,
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
    const wanted = try limitCount(definition_plan, bindings, limit);
    const count = @min(wanted, try input.rowCount());
    return .{
        .values = try allocator.dupe(
            execution.Value,
            input.values[0 .. count * input.width],
        ),
        .width = input.width,
    };
}

fn limitCount(
    definition_plan: *const definition.Plan,
    bindings: *const definition_core.parameters.Bindings,
    limit: plan.Limit,
) !usize {
    return switch (limit) {
        .fixed => |value| value,
        .parameter => |index| switch ((bindings.find(
            definition_plan.parameter_declarations.items[index].name,
        ) orelse return error.MissingObservationParameter).value) {
            .integer => |value| bound: {
                const count = std.math.cast(usize, value) orelse
                    return error.InvalidObservationLimit;
                if (count == 0 or count > definition_plan.bounds.max_rows) {
                    return error.InvalidObservationLimit;
                }
                break :bound count;
            },
            else => return error.ObservationLimitParameterMustBeInteger,
        },
    };
}

const SortContext = struct {
    table: Table,
    keys: []const plan.SortKey,

    fn lessThan(context: SortContext, a: usize, b: usize) bool {
        const left = context.table.row(a);
        const right = context.table.row(b);
        for (context.keys) |key| {
            const order = sortKeyOrder(key, left[key.field_index], right[key.field_index]);
            if (order != .eq) return order == .lt;
        }
        return a < b;
    }
};

fn sortKeyOrder(
    key: plan.SortKey,
    left: execution.Value,
    right: execution.Value,
) std.math.Order {
    return value_module.sortOrder(left, right, key.direction == .descending, key.nulls == .first);
}

fn sortTable(
    allocator: std.mem.Allocator,
    input: Table,
    sort: plan.Sort,
) !Table {
    return sortTablePrefix(allocator, input, sort, try input.rowCount());
}

fn sortTablePrefix(
    allocator: std.mem.Allocator,
    input: Table,
    sort: plan.Sort,
    selected_count: usize,
) !Table {
    const count = try input.rowCount();
    std.debug.assert(selected_count <= count);
    const indices = try allocator.alloc(usize, count);
    defer allocator.free(indices);
    for (indices, 0..) |*index, value| index.* = value;
    std.sort.heap(
        usize,
        indices,
        SortContext{ .table = input, .keys = sort.keys },
        SortContext.lessThan,
    );
    return copyIndexedRows(allocator, input, indices[0..selected_count]);
}

fn copyIndexedRows(
    allocator: std.mem.Allocator,
    input: Table,
    indices: []const usize,
) !Table {
    const values = try allocator.alloc(execution.Value, indices.len * input.width);
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
    var derivation = try expressions.Derivation.init(
        allocator,
        input_schema,
        &output_schema,
        config,
    );
    defer derivation.deinit();
    const values = try allocator.alloc(
        execution.Value,
        (try input.rowCount()) * output_schema.columns.len,
    );
    errdefer allocator.free(values);
    for (0..try input.rowCount()) |row_index| {
        const row = input.row(row_index);
        const out = values[row_index * output_schema.columns.len ..][0..output_schema.columns.len];
        try derivation.apply(&workspace, retained_allocator, bindings, selectors, row, out);
    }
    return .{ .values = values, .width = output_schema.columns.len };
}

const JoinContext = struct {
    allocator: std.mem.Allocator,
    left: Table,
    right: Table,
    spec: *const JoinSpec,
    output_width: usize,
    lineage: ?*LineageIndex,
    index: *const JoinIndex,
    max_rows: usize,

    fn first(self: *const JoinContext, row: []const execution.Value) ?usize {
        if (!joinFlagEnabled(self.spec.left_true, row)) return null;
        const hash = joinEqualityHash(self.spec.keys, row, .left) orelse return null;
        return self.index.first(hash);
    }

    fn matches(
        self: *const JoinContext,
        left: []const execution.Value,
        right: []const execution.Value,
    ) bool {
        if (!joinKeysMatch(self.spec.keys, left, right)) return false;
        if (self.lineage) |lineage| return lineage.matches(left, right);
        return true;
    }

    fn membership(self: *const JoinContext, input_is_exclusive: bool) !Table {
        const keep = try self.allocator.alloc(bool, try self.left.rowCount());
        defer self.allocator.free(keep);
        for (0..keep.len) |left_index| {
            const row = self.left.row(left_index);
            var matched = false;
            var candidate = self.first(row);
            while (candidate) |right_index| : (candidate = self.index.after(right_index)) {
                if (!self.matches(row, self.right.row(right_index))) continue;
                matched = true;
                break;
            }
            keep[left_index] = if (self.spec.kind == .anti) !matched else matched;
        }
        const copy_output = !input_is_exclusive or self.left.values.ptr == self.right.values.ptr;
        var retained: usize = 0;
        for (keep) |retain| if (retain) {
            retained += 1;
        };
        const output = if (copy_output)
            try self.allocator.alloc(execution.Value, retained * self.left.width)
        else
            self.left.values;
        var kept: usize = 0;
        for (keep, 0..) |retain, source_index| {
            if (!retain) continue;
            if (copy_output or kept != source_index) {
                @memcpy(
                    output[kept * self.left.width ..][0..self.left.width],
                    self.left.row(source_index),
                );
            }
            kept += 1;
        }
        return .{ .values = output[0 .. kept * self.left.width], .width = self.left.width };
    }

    fn materialize(self: *const JoinContext) !Table {
        const membership_join = self.spec.membership();
        var values: std.ArrayList(execution.Value) = .empty;
        errdefer values.deinit(self.allocator);
        for (0..try self.left.rowCount()) |left_index| {
            const row = self.left.row(left_index);
            var matched = false;
            var candidate = self.first(row);
            while (candidate) |right_index| : (candidate = self.index.after(right_index)) {
                const right = self.right.row(right_index);
                if (!self.matches(row, right)) continue;
                matched = true;
                if (membership_join) break;
                try appendJoinOutputs(self.allocator, &values, self.spec.outputs, row, right);
                if (values.items.len / self.output_width > self.max_rows) {
                    return error.ObservationRowBoundExceeded;
                }
            }
            const keeps_left_row = switch (self.spec.kind) {
                .anti => !matched,
                .semi => matched,
                .left => !matched,
                .inner => false,
            };
            if (keeps_left_row) {
                try appendJoinOutputs(self.allocator, &values, self.spec.outputs, row, null);
            }
        }
        return .{ .values = try values.toOwnedSlice(self.allocator), .width = self.output_width };
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
    input_is_exclusive: bool,
) !Table {
    var spec = try compileJoin(allocator, native_plan, step, config);
    defer spec.deinit(allocator);
    const left = tables[spec.left_stage] orelse return error.ObservationInputNotExecuted;
    const right = tables[spec.right_stage] orelse return error.ObservationInputNotExecuted;
    var lineage = if (spec.lineage) |columns| try LineageIndex.init(
        allocator,
        tables[columns.graph_stage] orelse return error.ObservationInputNotExecuted,
        columns,
        bounds.max_graph_depth,
    ) else null;
    defer if (lineage) |*index| index.deinit(allocator);
    var index = try JoinIndex.init(allocator, try right.rowCount());
    defer index.deinit(allocator);
    try populateJoinIndex(allocator, &index, right, &spec);
    const context: JoinContext = .{
        .allocator = allocator,
        .left = left,
        .right = right,
        .spec = &spec,
        .output_width = output_schema.columns.len,
        .lineage = if (lineage) |*value| value else null,
        .index = &index,
        .max_rows = bounds.max_rows,
    };
    if (spec.membership() and spec.projectsLeftColumns(left.width)) {
        return context.membership(input_is_exclusive);
    }
    return context.materialize();
}

const JoinKind = enum { inner, left, semi, anti };

const JoinOperator = enum { eq, lt, le, gt, ge };

const JoinSide = enum { left, right };

const JoinComparison = union(JoinOperator) {
    eq: bool,
    lt: void,
    le: void,
    gt: void,
    ge: void,
};

const JoinKey = struct {
    left: u16,
    right: u16,
    comparison: JoinComparison,
};

const JoinOutput = struct {
    side: JoinSide,
    column: u16,
};

const JoinLineage = struct {
    graph_stage: u16,
    node: u16,
    parent: u16,
    left: u16,
    right: u16,
};

const JoinSpec = struct {
    kind: JoinKind,
    left_stage: u16,
    right_stage: u16,
    keys: []JoinKey,
    left_true: ?u16,
    right_true: ?u16,
    lineage: ?JoinLineage,
    outputs: []JoinOutput,

    fn deinit(self: *JoinSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.keys);
        allocator.free(self.outputs);
        self.* = undefined;
    }

    fn membership(self: *const JoinSpec) bool {
        return self.kind == .semi or self.kind == .anti;
    }

    fn projectsLeftColumns(self: *const JoinSpec, width: usize) bool {
        if (self.outputs.len != width) return false;
        for (self.outputs, 0..) |output, column| {
            if (output.side != .left or output.column != column) return false;
        }
        return true;
    }
};

fn compileJoin(
    allocator: std.mem.Allocator,
    native_plan: *const plan.Plan,
    step: definition.Step,
    config: []const u8,
) !JoinSpec {
    var parsed = try parseConfig(allocator, config);
    defer parsed.deinit();
    const root = try definition_core.json.object(parsed.value);
    const on = try definition_core.json.object(try definition_core.json.field(root, "on"));
    try requireJoinOptions(on, &.{ "kind", "keys", "left_true", "right_true", "lineage" });
    const lineage = on.get("lineage");
    if (lineage != null and step.input_names.len != 3) {
        return error.ObservationLineageInputMissing;
    }
    if (step.input_names.len < 2 or step.input_names.len > 3) {
        return error.InvalidPipelineInputCount;
    }
    const left_stage = try joinInputStage(native_plan, step, 0);
    const right_stage = try joinInputStage(native_plan, step, 1);
    const left = native_plan.stages[left_stage].schema;
    const right = native_plan.stages[right_stage].schema;
    const kind = if (on.get("kind")) |raw|
        std.meta.stringToEnum(JoinKind, try definition_core.json.string(raw)) orelse
            return error.ObservationJoinKindUnsupported
    else
        JoinKind.inner;
    const left_true = try compileJoinFlag(on, "left_true", left);
    const right_true = try compileJoinFlag(on, "right_true", right);
    const keys = try compileJoinKeys(allocator, try configArray(on, "keys"), left, right);
    errdefer allocator.free(keys);
    const outputs = try compileJoinOutputs(
        allocator,
        try configArray(root, "fields"),
        left,
        right,
        kind,
    );
    errdefer allocator.free(outputs);
    return .{
        .kind = kind,
        .left_stage = left_stage,
        .right_stage = right_stage,
        .keys = keys,
        .left_true = left_true,
        .right_true = right_true,
        .lineage = if (lineage) |raw|
            try compileJoinLineage(native_plan, step, try definition_core.json.object(raw))
        else
            null,
        .outputs = outputs,
    };
}

fn joinInputStage(native_plan: *const plan.Plan, step: definition.Step, input: usize) !u16 {
    return native_plan.findStage(step.input_names[input]) orelse
        error.ObservationExternalGraphInputUnsupported;
}

fn compileJoinFlag(on: std.json.ObjectMap, name: []const u8, schema: plan.Schema) !?u16 {
    const raw = on.get(name) orelse return null;
    const column = schema.find(try definition_core.json.string(raw)) orelse
        return error.UnknownObservationJoinField;
    if (schema.columns[column].kind != .boolean) return error.ObservationJoinFlagRequiresBoolean;
    return column;
}

fn compileJoinKeys(
    allocator: std.mem.Allocator,
    keys: std.json.Array,
    left: plan.Schema,
    right: plan.Schema,
) ![]JoinKey {
    const compiled = try allocator.alloc(JoinKey, keys.items.len);
    errdefer allocator.free(compiled);
    var equality_keys: usize = 0;
    for (keys.items, compiled) |item, *key| {
        const object = try definition_core.json.object(item);
        try requireJoinOptions(object, &.{ "left", "right", "op", "nulls_equal" });
        const op = if (object.get("op")) |raw|
            std.meta.stringToEnum(JoinOperator, try definition_core.json.string(raw)) orelse
                return error.ObservationJoinOperatorUnsupported
        else
            JoinOperator.eq;
        const nulls_equal = if (object.get("nulls_equal")) |raw|
            try definition_core.json.boolean(raw)
        else
            false;
        if (nulls_equal and op != .eq) return error.ObservationJoinNullsEqualRequiresEquality;
        key.* = .{
            .left = left.find(try definition_core.json.requiredString(object, "left")) orelse
                return error.UnknownObservationJoinField,
            .right = right.find(try definition_core.json.requiredString(object, "right")) orelse
                return error.UnknownObservationJoinField,
            .comparison = switch (op) {
                .eq => .{ .eq = nulls_equal },
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                .ge => .ge,
            },
        };
        if (op == .eq) equality_keys += 1;
    }
    if (equality_keys == 0) return error.ObservationJoinRequiresEqualityKey;
    return compiled;
}

fn compileJoinOutputs(
    allocator: std.mem.Allocator,
    fields: std.json.Array,
    left: plan.Schema,
    right: plan.Schema,
    kind: JoinKind,
) ![]JoinOutput {
    const outputs = try allocator.alloc(JoinOutput, fields.items.len);
    errdefer allocator.free(outputs);
    for (fields.items, outputs) |item, *output| {
        const field = try definition_core.json.object(item);
        try requireJoinOptions(field, &.{ "source", "field", "name", "type", "nullable" });
        const source = try definition_core.json.unsigned(
            try definition_core.json.field(field, "source"),
        );
        const side: JoinSide = switch (source) {
            0 => .left,
            1 => .right,
            else => return error.ObservationJoinSourceUnsupported,
        };
        if (side == .right and (kind == .semi or kind == .anti)) {
            return error.ObservationMembershipJoinProjectsRight;
        }
        const schema = if (side == .left) left else right;
        output.* = .{
            .side = side,
            .column = schema.find(try definition_core.json.requiredString(field, "field")) orelse
                return error.UnknownObservationJoinField,
        };
    }
    return outputs;
}

fn compileJoinLineage(
    native_plan: *const plan.Plan,
    step: definition.Step,
    config: std.json.ObjectMap,
) !JoinLineage {
    try requireJoinOptions(config, &.{ "node", "parent", "left", "right" });
    const graph_stage = try joinInputStage(native_plan, step, 2);
    const graph = native_plan.stages[graph_stage].schema;
    const left = native_plan.stages[try joinInputStage(native_plan, step, 0)].schema;
    const right = native_plan.stages[try joinInputStage(native_plan, step, 1)].schema;
    return .{
        .graph_stage = graph_stage,
        .node = try lineageColumn(graph, config, "node"),
        .parent = try lineageColumn(graph, config, "parent"),
        .left = try lineageColumn(left, config, "left"),
        .right = try lineageColumn(right, config, "right"),
    };
}

fn lineageColumn(schema: plan.Schema, config: std.json.ObjectMap, name: []const u8) !u16 {
    return schema.find(try definition_core.json.requiredString(config, name)) orelse
        error.UnknownObservationLineageField;
}

fn requireJoinOptions(object: std.json.ObjectMap, allowed: []const []const u8) !void {
    for (object.keys()) |key| {
        if (!namesOneOf(allowed, key)) return error.UnknownObservationJoinOption;
    }
}

fn namesOneOf(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, wanted)) return true;
    return false;
}

fn populateJoinIndex(
    allocator: std.mem.Allocator,
    index: *JoinIndex,
    right: Table,
    spec: *const JoinSpec,
) !void {
    for (0..try right.rowCount()) |row_index| {
        const row = right.row(row_index);
        if (!joinFlagEnabled(spec.right_true, row)) continue;
        const hash = joinEqualityHash(spec.keys, row, .right) orelse continue;
        try index.add(allocator, hash, row_index);
    }
}

fn joinFlagEnabled(column: ?u16, row: []const execution.Value) bool {
    const index = column orelse return true;
    return switch (row[index]) {
        .boolean => |flag| flag,
        else => false,
    };
}

fn joinEqualityHash(keys: []const JoinKey, row: []const execution.Value, side: JoinSide) ?u64 {
    var hash = std.hash.Wyhash.init(0);
    for (keys) |key| {
        const nulls_equal = switch (key.comparison) {
            .eq => |value| value,
            else => continue,
        };
        const value = row[if (side == .left) key.left else key.right];
        if (value == .null and !nulls_equal) return null;
        hashValue(&hash, value);
    }
    return hash.final();
}

fn joinKeysMatch(
    keys: []const JoinKey,
    left: []const execution.Value,
    right: []const execution.Value,
) bool {
    for (keys) |key| {
        const left_value = left[key.left];
        const right_value = right[key.right];
        const matched = switch (key.comparison) {
            .eq => |nulls_equal| if (left_value == .null or right_value == .null)
                nulls_equal and left_value == .null and right_value == .null
            else
                valuesEqual(left_value, right_value, false),
            .lt => value_module.holds(left_value, right_value, .lt),
            .le => value_module.holds(left_value, right_value, .le),
            .gt => value_module.holds(left_value, right_value, .gt),
            .ge => value_module.holds(left_value, right_value, .ge),
        };
        if (!matched) return false;
    }
    return true;
}

fn appendJoinOutputs(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(execution.Value),
    outputs: []const JoinOutput,
    left: []const execution.Value,
    right: ?[]const execution.Value,
) !void {
    for (outputs) |field| {
        try output.append(allocator, switch (field.side) {
            .left => left[field.column],
            .right => if (right) |row| row[field.column] else .null,
        });
    }
}

pub const StreamingLineageReducer = struct {
    allocator: std.mem.Allocator,
    spec: JoinSpec,
    width: usize,
    lineage: LineageIndex,
    heads: std.AutoHashMapUnmanaged(u64, usize) = .{},
    next: std.ArrayList(usize) = .empty,
    output: std.ArrayList(execution.Value) = .empty,
    max_rows: usize,
    max_retained_bytes: usize,

    const no_owner = std.math.maxInt(usize);

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
        var spec = try compileJoin(
            allocator,
            native_plan,
            definition_plan.steps[schedule.lineage_stage],
            generic.canonical_config,
        );
        errdefer spec.deinit(allocator);
        if (!streamableLineageJoin(native_plan, &spec)) {
            return error.ObservationStreamingLineageShapeUnsupported;
        }
        var lineage = try LineageIndex.init(
            allocator,
            graph,
            spec.lineage.?,
            definition_plan.bounds.max_graph_depth,
        );
        errdefer lineage.deinit(allocator);
        std.debug.assert(stage.schema.columns.len == spec.outputs.len);
        return .{
            .allocator = allocator,
            .spec = spec,
            .width = native_plan.stages[spec.left_stage].schema.columns.len,
            .lineage = lineage,
            .max_rows = definition_plan.bounds.max_rows,
            .max_retained_bytes = max_retained_bytes,
        };
    }

    pub fn deinit(self: *StreamingLineageReducer) void {
        self.lineage.deinit(self.allocator);
        self.spec.deinit(self.allocator);
        self.heads.deinit(self.allocator);
        self.next.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendPartition(self: *StreamingLineageReducer, rows: Table) !void {
        if (rows.width != self.width) return error.InvalidObservationRows;
        for (0..try rows.rowCount()) |row_index| {
            const row = rows.row(row_index);
            const key_hash = joinEqualityHash(self.spec.keys, row, .left) orelse {
                try self.retain(row, null);
                continue;
            };
            if (joinFlagEnabled(self.spec.left_true, row) and
                self.ancestorMatches(row, key_hash)) continue;
            const owner = joinFlagEnabled(self.spec.right_true, row);
            try self.retain(row, if (owner) key_hash else null);
        }
    }

    fn ancestorMatches(
        self: *const StreamingLineageReducer,
        row: []const execution.Value,
        key_hash: u64,
    ) bool {
        var candidate = self.heads.get(key_hash);
        while (candidate) |owner_index| {
            const owner = self.ownerRow(owner_index);
            if (joinKeysMatch(self.spec.keys, row, owner) and
                self.lineage.matches(row, owner)) return true;
            const following = self.next.items[owner_index];
            candidate = if (following == no_owner) null else following;
        }
        return false;
    }

    fn retain(
        self: *StreamingLineageReducer,
        row: []const execution.Value,
        owner_hash: ?u64,
    ) !void {
        const output_index = self.rowCount();
        try self.output.appendSlice(self.allocator, row);
        if (owner_hash) |hash| {
            const entry = try self.heads.getOrPut(self.allocator, hash);
            try self.next.append(
                self.allocator,
                if (entry.found_existing) entry.value_ptr.* else no_owner,
            );
            entry.value_ptr.* = output_index;
        } else try self.next.append(self.allocator, no_owner);
        try self.checkBounds();
    }

    fn checkBounds(self: *const StreamingLineageReducer) !void {
        if (self.rowCount() > self.max_rows) return error.ObservationRowBoundExceeded;
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
        if (self.spec.projectsLeftColumns(self.width)) {
            const values = try self.output.toOwnedSlice(self.allocator);
            self.output = .empty;
            return .{ .values = values, .width = self.width };
        }
        const rows = self.rowCount();
        const width = self.spec.outputs.len;
        const values = try self.allocator.alloc(
            execution.Value,
            try std.math.mul(usize, rows, width),
        );
        for (0..rows) |row_index| {
            const row = self.ownerRow(row_index);
            const target = values[row_index * width ..][0..width];
            for (self.spec.outputs, target) |output, *value| value.* = row[output.column];
        }
        self.output.clearAndFree(self.allocator);
        return .{ .values = values, .width = width };
    }

    pub fn rowCount(self: *const StreamingLineageReducer) usize {
        return self.output.items.len / self.width;
    }

    fn ownerRow(self: *const StreamingLineageReducer, index: usize) []const execution.Value {
        return self.output.items[index * self.width ..][0..self.width];
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

fn hashValue(hash: *std.hash.Wyhash, value: execution.Value) void {
    if (valueFloat(value)) |number| {
        const bits: u64 = @bitCast(if (number == 0) @as(f64, 0) else number);
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
    parent_index: u16,
    left_index: u16,
    right_index: u16,
    nodes: std.StringHashMapUnmanaged(usize) = .{},
    parents: []?usize = &.{},

    fn init(
        allocator: std.mem.Allocator,
        rows: Table,
        columns: JoinLineage,
        max_depth: usize,
    ) !LineageIndex {
        var result = LineageIndex{
            .rows = rows,
            .parent_index = columns.parent,
            .left_index = columns.left,
            .right_index = columns.right,
        };
        errdefer result.deinit(allocator);
        for (0..try rows.rowCount()) |row_index| {
            const value = rows.row(row_index)[columns.node];
            if (value == .null) continue;
            const node = valueText(value) orelse return error.InvalidObservationLineageNode;
            const entry = try result.nodes.getOrPut(allocator, node);
            if (entry.found_existing) return error.DuplicateObservationLineageNode;
            entry.value_ptr.* = row_index;
        }
        result.parents = try parentLinks(
            allocator,
            rows,
            columns.node,
            columns.parent,
            &result.nodes,
            false,
        );
        try requireBoundedAncestry(allocator, result.parents, max_depth);
        return result;
    }

    fn deinit(self: *LineageIndex, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        allocator.free(self.parents);
        self.* = undefined;
    }

    fn matches(
        self: *const LineageIndex,
        left: []const execution.Value,
        right: []const execution.Value,
    ) bool {
        const descendant = valueText(left[self.left_index]) orelse return false;
        const ancestor = valueText(right[self.right_index]) orelse return false;
        var current = self.nodes.get(descendant) orelse return false;
        for (0..self.parents.len) |_| {
            const parent = valueText(self.rows.row(current)[self.parent_index]) orelse
                return false;
            if (std.mem.eql(u8, parent, ancestor)) return true;
            current = self.parents[current] orelse return false;
        }
        unreachable;
    }
};

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
        const value = input.row(index)[node_index];
        if (value == .null) continue;
        const node = valueText(value) orelse return error.InvalidObservationReachabilityNode;
        const entry = try nodes.getOrPut(allocator, node);
        if (entry.found_existing) return error.DuplicateObservationReachabilityNode;
        entry.value_ptr.* = index;
    }
    const parents = try parentLinks(allocator, input, node_index, parent_index, &nodes, true);
    defer allocator.free(parents);
    try requireBoundedAncestry(allocator, parents, bounds.max_graph_depth);
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
                parents,
                bounds,
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
        parents,
        bounds,
    );
}

fn parentLinks(
    allocator: std.mem.Allocator,
    rows: Table,
    node_index: u16,
    parent_index: u16,
    nodes: *const std.StringHashMapUnmanaged(usize),
    comptime text_parents: bool,
) ![]?usize {
    const parents = try allocator.alloc(?usize, try rows.rowCount());
    errdefer allocator.free(parents);
    for (parents, 0..) |*parent, index| {
        const row = rows.row(index);
        parent.* = null;
        if (row[node_index] == .null or row[parent_index] == .null) continue;
        const text = valueText(row[parent_index]) orelse {
            if (text_parents) return error.InvalidObservationReachabilityNode;
            continue;
        };
        parent.* = nodes.get(text);
    }
    return parents;
}

fn requireBoundedAncestry(
    allocator: std.mem.Allocator,
    parents: []const ?usize,
    max_depth: usize,
) !void {
    const depths = try allocator.alloc(usize, parents.len);
    defer allocator.free(depths);
    const settled = try allocator.alloc(bool, parents.len);
    defer allocator.free(settled);
    const visiting = try allocator.alloc(bool, parents.len);
    defer allocator.free(visiting);
    @memset(settled, false);
    @memset(visiting, false);
    var path: std.ArrayList(usize) = .empty;
    defer path.deinit(allocator);
    for (0..parents.len) |start| {
        path.clearRetainingCapacity();
        var current: ?usize = start;
        while (current) |node| {
            if (settled[node]) break;
            if (visiting[node]) return error.ObservationGraphCycle;
            visiting[node] = true;
            try path.append(allocator, node);
            current = parents[node];
        }
        var remaining = path.items.len;
        while (remaining > 0) {
            remaining -= 1;
            const node = path.items[remaining];
            depths[node] = if (parents[node]) |parent| depths[parent] + 1 else 0;
            if (depths[node] > max_depth) return error.ObservationGraphDepthExceeded;
            settled[node] = true;
        }
    }
}

fn reachabilitySeeded(
    allocator: std.mem.Allocator,
    input: Table,
    input_schema: *const plan.Schema,
    output_schema: plan.Schema,
    fields: std.json.Array,
    keys: std.json.ObjectMap,
    parents: []const ?usize,
    bounds: definition.Bounds,
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
    expandReachability(
        parents,
        bounds.max_graph_depth,
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
    parents: []const ?usize,
    max_depth: usize,
    walk_ancestors: bool,
    walk_descendants: bool,
    reachable: []bool,
    depths: []i64,
) void {
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        var changed = false;
        for (parents, 0..) |parent, child_index| {
            const candidate_index = parent orelse continue;
            if (walk_ancestors and reachable[child_index] and !reachable[candidate_index]) {
                reachable[candidate_index] = true;
                depths[candidate_index] = depths[child_index] + 1;
                changed = true;
            }
            if (walk_descendants and reachable[candidate_index] and !reachable[child_index]) {
                reachable[child_index] = true;
                depths[child_index] = depths[candidate_index] + 1;
                changed = true;
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
    parents: []const ?usize,
    bounds: definition.Bounds,
) !Table {
    const count = try input.rowCount();
    var output: std.ArrayList(execution.Value) = .empty;
    errdefer output.deinit(allocator);
    for (0..count) |descendant_index| {
        const descendant = input.row(descendant_index);
        var current = parents[descendant_index];
        var depth: usize = 1;
        while (current) |found| : (depth += 1) {
            std.debug.assert(depth <= bounds.max_graph_depth and found != descendant_index);
            const ancestor = input.row(found);
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
            current = parents[found];
        }
    }
    return .{
        .values = try output.toOwnedSlice(allocator),
        .width = output_schema.columns.len,
    };
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

fn expectGraphTopK(input: Table, keys: []plan.SortKey, limit: usize) !void {
    const allocator = std.testing.allocator;
    const sorted = try sortTable(allocator, input, .{ .keys = keys });
    defer allocator.free(sorted.values);
    const selected = try topKTable(
        allocator,
        &graph_test_definition,
        &expression_test_bindings,
        input,
        .{ .keys = keys, .limit = .{ .fixed = limit } },
    );
    defer allocator.free(selected.values);
    const count = @min(try input.rowCount(), limit) * input.width;
    try std.testing.expectEqual(count, selected.values.len);
    for (sorted.values[0..count], selected.values) |expected, actual| {
        if (expected == .float) {
            try std.testing.expect(actual == .float);
            try std.testing.expectEqual(
                @as(u64, @bitCast(expected.float)),
                @as(u64, @bitCast(actual.float)),
            );
        } else try std.testing.expectEqualDeep(expected, actual);
    }
}

test "graph bounded top-k matches full sorting for ties nulls directions and capacities" {
    var values: [771]execution.Value = undefined;
    const tags = [_][]const u8{ "a", "b", "c" };
    for (0..257) |index| {
        const number: i64 = @as(i64, @intCast((index * 13) % 23)) - 11;
        values[index * 3] = switch (index % 3) {
            0 => .{ .integer = number },
            1 => .{ .float = @floatFromInt(number) },
            else => .null,
        };
        values[index * 3 + 1] = .{ .string = tags[index % tags.len] };
        values[index * 3 + 2] = .{ .integer = @intCast(index) };
    }
    var keys = [_]plan.SortKey{
        .{ .field_index = 0, .direction = .ascending, .nulls = .last },
        .{ .field_index = 1, .direction = .descending, .nulls = .first },
    };
    for ([_]plan.SortDirection{ .ascending, .descending }) |direction| {
        keys[0].direction = direction;
        for ([_]plan.NullOrder{ .first, .last }) |nulls| {
            keys[0].nulls = nulls;
            for ([_]usize{ 0, 1, 2, 32, 257 }) |count| {
                const input = Table{ .values = values[0 .. count * 3], .width = 3 };
                try std.testing.expect(hasTotalSortOrder(input, &keys));
                for ([_]usize{ 0, 1, 2, 10, 256, 257, 258 }) |limit| {
                    try expectGraphTopK(input, &keys, limit);
                }
                for ([_]usize{ count / 2, count / 2 + 1, count -| 1 }) |limit| {
                    try expectGraphTopK(input, &keys, limit);
                }
            }
        }
    }
}

test "graph top-k preserves full-sort behavior for incomparable keys and infinities" {
    var keys = [_]plan.SortKey{
        .{ .field_index = 0, .direction = .ascending, .nulls = .last },
    };
    var mixed = [_]execution.Value{
        .{ .integer = 3 }, .{ .string = "a" }, .{ .integer = 2 }, .{ .boolean = true },
    };
    var numeric = [_]execution.Value{
        .{ .float = 3 },                  .{ .float = std.math.inf(f64) },
        .{ .float = -std.math.inf(f64) }, .{ .float = 2 },
    };
    const cases = [_]Table{
        .{ .values = &mixed, .width = 1 },
        .{ .values = &numeric, .width = 1 },
    };
    for (cases) |input| {
        try std.testing.expect(!hasTotalSortOrder(input, &keys));
        for (0..input.values.len + 1) |limit| try expectGraphTopK(input, &keys, limit);
    }
    // NaN is outside std.math.order's domain, so only test its heap exclusion.
    var nan = [_]execution.Value{.{ .float = std.math.nan(f64) }};
    try std.testing.expect(!hasTotalSortOrder(.{ .values = &nan, .width = 1 }, &keys));
}

fn graphTopKAllocationProbe(allocator: std.mem.Allocator, limit: usize) !void {
    var values = [_]execution.Value{
        .{ .integer = 5 }, .{ .integer = 1 }, .{ .integer = 4 }, .{ .integer = 2 },
    };
    var keys = [_]plan.SortKey{
        .{ .field_index = 0, .direction = .ascending, .nulls = .last },
    };
    const selected = try topKTable(
        allocator,
        &graph_test_definition,
        &expression_test_bindings,
        .{ .values = &values, .width = 1 },
        .{ .keys = &keys, .limit = .{ .fixed = limit } },
    );
    defer allocator.free(selected.values);
    try std.testing.expectEqual(limit, selected.values.len);
    const expected = [_]i64{ 1, 2, 4, 5 };
    for (selected.values, expected[0..limit]) |actual, wanted| {
        try std.testing.expectEqual(wanted, actual.integer);
    }
}

test "graph top-k releases its bounded index and output at every allocation failure" {
    for ([_]usize{ 2, 3 }) |limit| {
        try @import("test_support").checkAllAllocationFailures(
            std.testing.allocator,
            graphTopKAllocationProbe,
            .{limit},
        );
    }
}

test "lineage ownership is strict and does not cross siblings" {
    var graph_values = [_]execution.Value{
        .{ .string = "root" },       .null,
        .{ .string = "child-a" },    .{ .string = "root" },
        .{ .string = "child-b" },    .{ .string = "root" },
        .{ .string = "grandchild" }, .{ .string = "child-a" },
    };
    var index = try LineageIndex.init(
        std.testing.allocator,
        .{ .values = &graph_values, .width = 2 },
        .{ .graph_stage = 0, .node = 0, .parent = 1, .left = 0, .right = 0 },
        8,
    );
    defer index.deinit(std.testing.allocator);
    const child = [_]execution.Value{.{ .string = "child-a" }};
    const sibling = [_]execution.Value{.{ .string = "child-b" }};
    const root = [_]execution.Value{.{ .string = "root" }};
    const grandchild = [_]execution.Value{.{ .string = "grandchild" }};
    try std.testing.expect(index.matches(&child, &root));
    try std.testing.expect(index.matches(&grandchild, &root));
    try std.testing.expect(!index.matches(&child, &sibling));
    try std.testing.expect(!index.matches(&child, &child));
}

test "join equality hashes null-safe cumulative tuples consistently" {
    const keys = [_]JoinKey{
        .{ .left = 0, .right = 0, .comparison = .{ .eq = false } },
        .{ .left = 1, .right = 1, .comparison = .{ .eq = true } },
    };
    const row = [_]execution.Value{ .{ .integer = 42 }, .null };
    try std.testing.expect(joinEqualityHash(&keys, &row, .left) != null);
    try std.testing.expectEqual(
        joinEqualityHash(&keys, &row, .left),
        joinEqualityHash(&keys, &row, .right),
    );
    try std.testing.expect(joinKeysMatch(&keys, &row, &row));
    const strict = [_]JoinKey{.{ .left = 1, .right = 1, .comparison = .{ .eq = false } }};
    try std.testing.expect(joinEqualityHash(&strict, &row, .left) == null);
    try std.testing.expect(!joinKeysMatch(&strict, &row, &row));
}

const lineage_eligibility_rows = [_]execution.Value{
    .{ .string = "root" },
    .{ .integer = 10 },
    .{ .boolean = true },
    .{ .boolean = true },
    .{ .string = "child" },
    .{ .integer = 20 },
    .{ .boolean = false },
    .{ .boolean = true },
    .{ .string = "child" },
    .{ .integer = 30 },
    .{ .boolean = false },
    .{ .boolean = false },
    .{ .string = "grandchild" },
    .{ .integer = 20 },
    .{ .boolean = true },
    .{ .boolean = true },
    .{ .string = "grandchild" },
    .{ .integer = 30 },
    .{ .boolean = true },
    .{ .boolean = true },
};

test "streaming lineage keeps right eligibility independent of left eligibility" {
    const graph_columns = [_]plan.Column{
        .{ .name = @constCast("node"), .kind = .string, .nullable = false },
        .{ .name = @constCast("parent"), .kind = .string, .nullable = true },
    };
    const columns = [_]plan.Column{
        .{ .name = @constCast("node"), .kind = .string, .nullable = false },
        .{ .name = @constCast("key"), .kind = .integer, .nullable = false },
        .{ .name = @constCast("left"), .kind = .boolean, .nullable = false },
        .{ .name = @constCast("right"), .kind = .boolean, .nullable = false },
    };
    var graph_values = [_]execution.Value{
        .{ .string = "root" },       .null,
        .{ .string = "child" },      .{ .string = "root" },
        .{ .string = "grandchild" }, .{ .string = "child" },
    };
    const keys = try std.testing.allocator.alloc(JoinKey, 1);
    keys[0] = .{ .left = 1, .right = 1, .comparison = .{ .eq = false } };
    const outputs = std.testing.allocator.alloc(JoinOutput, columns.len) catch |err| {
        std.testing.allocator.free(keys);
        return err;
    };
    for (outputs, 0..) |*output, index| output.* = .{ .side = .left, .column = @intCast(index) };
    const lineage: JoinLineage = .{
        .graph_stage = 0,
        .node = 0,
        .parent = 1,
        .left = 0,
        .right = 0,
    };
    var reducer: StreamingLineageReducer = .{
        .allocator = std.testing.allocator,
        .spec = .{
            .kind = .anti,
            .left_stage = 1,
            .right_stage = 1,
            .keys = keys,
            .left_true = 2,
            .right_true = 3,
            .lineage = lineage,
            .outputs = outputs,
        },
        .width = columns.len,
        .lineage = try LineageIndex.init(
            std.testing.allocator,
            .{ .values = &graph_values, .width = graph_columns.len },
            lineage,
            8,
        ),
        .max_rows = 10,
        .max_retained_bytes = 4096,
    };
    defer reducer.deinit();
    try reducer.appendPartition(.{
        .values = @constCast(&lineage_eligibility_rows),
        .width = columns.len,
    });
    const result = try reducer.finish();
    defer std.testing.allocator.free(result.values);
    try std.testing.expectEqual(@as(usize, 4), try result.rowCount());
    try std.testing.expectEqualStrings("grandchild", result.row(3)[0].string);
    try std.testing.expectEqual(@as(i64, 30), result.row(3)[1].integer);
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
        \\        {"source":0,"field":"role","name":"role","type":"string","nullable":true},
        \\        {"source":0,"field":"source_event_id","name":"source_event_id","type":"string","nullable":false}
        \\      ]}
        \\  ],
        \\  "projections":{"rows":{"relation":"owned_rows","schema":"test/message-lineage/v1","fields":["session_id","role","source_event_id"],"renderers":["json"]}},
        \\  "bounds":{"max_rows":100,"max_output_bytes":4096,"max_fold_states":4,"max_input_bytes":1048576,"max_graph_depth":8,"max_graph_nodes":100,"max_diagnostics":8}
        \\}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "definition.json", .data = source });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.io,
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
    .values_digest = @as([71]u8, @splat(0)),
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

test "text prefixes preserve UTF-8 and reject invalid bounds in both evaluators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { text: []const u8, bound: i64, expected: []const u8 }{
        .{ .text = "plain", .bound = 0, .expected = "" },
        .{ .text = "plain", .bound = 3, .expected = "pla" },
        .{ .text = "plain", .bound = 100, .expected = "plain" },
        .{ .text = "aé🌱z", .bound = 2, .expected = "a" },
        .{ .text = "aé🌱z", .bound = 3, .expected = "aé" },
        .{ .text = "aé🌱z", .bound = 6, .expected = "aé" },
        .{ .text = "aé🌱z", .bound = 7, .expected = "aé🌱" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(
            arena.allocator(),
            "{{\"op\":\"text-prefix\",\"args\":[\"{s}\",{d}]}}",
            .{ case.text, case.bound },
        );
        for ([_]bool{ false, true }) |compiled| {
            const actual = try testExpressionValue(arena.allocator(), source, compiled);
            try std.testing.expectEqualStrings(case.expected, actual.string);
            try std.testing.expect(std.unicode.utf8ValidateSlice(actual.string));
        }
    }
    for ([_]bool{ false, true }) |compiled| {
        try std.testing.expectEqual(execution.Value.null, try testExpressionValue(
            arena.allocator(),
            "{\"op\":\"text-prefix\",\"args\":[null,8]}",
            compiled,
        ));
        try std.testing.expectError(error.InvalidObservationTextBound, testExpressionValue(
            arena.allocator(),
            "{\"op\":\"text-prefix\",\"args\":[\"text\",-1]}",
            compiled,
        ));
        for ([_][]const u8{
            "{\"op\":\"text-prefix\",\"args\":[42,8]}",
            "{\"op\":\"text-prefix\",\"args\":[\"text\",2.5]}",
            "{\"op\":\"text-prefix\",\"args\":[\"text\",null]}",
        }) |source| {
            try std.testing.expectError(
                error.ObservationExpressionTypeMismatch,
                testExpressionValue(arena.allocator(), source, compiled),
            );
        }
    }
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
    try @import("test_support").checkAllAllocationFailures(
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
    .closure_digest = @as([71]u8, @splat(0)),
    .operator_mask = 0,
    .parameter_declarations = .{
        .items = &.{},
        .shape_digest = @as([71]u8, @splat(0)),
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
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        exerciseGraphAllocationFailures,
        .{@as(usize, 3)},
    );
    try @import("test_support").checkAllAllocationFailures(
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

fn exerciseSharedGraph(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    native_plan: *const plan.Plan,
    owned: bool,
    count: usize,
    folded: bool,
) !void {
    const expected = [_]execution.Value{
        .{ .string = "assistant" }, .{ .string = "first" },
        .{ .string = "user" },      .{ .string = "second" },
    };
    var borrowed = expected;
    const values = if (owned)
        try allocator.dupe(execution.Value, expected[0 .. count * 2])
    else
        borrowed[0 .. count * 2];
    var scans = [_]ScanInput{
        .{ .stage_index = 0, .table = .{ .values = values, .width = 2 }, .owned = owned },
    };
    defer if (scans[0].owned) allocator.free(values);
    const result = try executeTarget(
        allocator,
        allocator,
        definition_plan,
        native_plan,
        &expression_test_bindings,
        .{},
        native_plan.findStage("rows").?,
        &scans,
    );
    defer allocator.free(result.table.values);
    try std.testing.expectEqual(count, try result.table.rowCount());
    for (0..count) |index| {
        const row = result.table.row(index);
        try std.testing.expectEqualDeep(expected[index * 2], row[0]);
        try std.testing.expectEqualDeep(expected[index * 2 + 1], row[1]);
        try std.testing.expectEqualDeep(
            if (folded or index == 1) expected[index * 2] else execution.Value.null,
            row[2],
        );
    }
    if (!owned) try std.testing.expectEqualDeep(expected, borrowed);
}

test "streaming lineage falls back when the projection reads an unseeded scan" {
    const Case = struct { source: []const u8, streams: bool };
    const cases = [_]Case{
        .{ .source = @embedFile("fixtures/lineage-observation.json"), .streams = true },
        .{ .source = @embedFile("fixtures/lineage-control-parent.json"), .streams = false },
        .{ .source = @embedFile("fixtures/lineage-extra-scan.json"), .streams = false },
        .{ .source = @embedFile("fixtures/lineage-token-filter.json"), .streams = false },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "definition.json",
            .data = case.source,
        });
        var closure = try definition_core.closure.loadFromDir(
            std.testing.io,
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
        const schedule = try streamingLineagePlan(
            std.testing.allocator,
            &definition_plan,
            &native_plan,
            "rows",
        );
        try std.testing.expectEqual(case.streams, schedule != null);
        if (case.streams or native_plan.findStage("joined_rows") == null) continue;
        var scans = [_]ScanInput{
            .{
                .stage_index = native_plan.findStage("session_rows").?,
                .table = .{ .values = &.{}, .width = 2 },
            },
            .{
                .stage_index = native_plan.findStage("owned_rows").?,
                .table = .{ .values = &.{}, .width = 3 },
            },
        };
        try std.testing.expectError(error.ObservationInputNotExecuted, executeTarget(
            std.testing.allocator,
            std.testing.allocator,
            &definition_plan,
            &native_plan,
            &expression_test_bindings,
            .{},
            native_plan.findStage("joined_rows").?,
            &scans,
        ));
    }
}

test "branching filters membership joins and folds preserve shared inputs and ownership" {
    const sources = [_][]const u8{
        @embedFile("fixtures/shared-filter.json"),
        @embedFile("fixtures/shared-membership.json"),
        @embedFile("fixtures/shared-fold.json"),
    };
    for (sources, 0..) |source, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "definition.json", .data = source });
        var closure = try definition_core.closure.loadFromDir(
            std.testing.io,
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
        for ([_]bool{ false, true }) |owned| {
            for ([_]usize{ 0, 1, 2 }) |count| {
                try exerciseSharedGraph(
                    std.testing.allocator,
                    &definition_plan,
                    &native_plan,
                    owned,
                    count,
                    index == 2,
                );
            }
            try @import("test_support").checkAllAllocationFailures(
                std.testing.allocator,
                exerciseSharedGraph,
                .{ &definition_plan, &native_plan, owned, @as(usize, 2), index == 2 },
            );
        }
    }
}

test "integer comparison and distinct preserve adjacent values beyond float precision" {
    const low: execution.Value = .{ .integer = 9_007_199_254_740_992 };
    const high: execution.Value = .{ .integer = 9_007_199_254_740_993 };
    try std.testing.expect(!valuesEqual(low, high, false));
    try std.testing.expectEqual(std.math.Order.lt, value_module.order(low, high));
    try std.testing.expectEqual(std.math.Order.gt, value_module.order(high, low));
    try std.testing.expect(!valuesEqual(
        .{ .integer = std.math.maxInt(i64) - 1 },
        .{ .integer = std.math.maxInt(i64) },
        false,
    ));
    var values = [_]execution.Value{ low, high, low };
    var keys = [_]u16{0};
    const distinct = try distinctTable(
        std.testing.allocator,
        .{ .values = &values, .width = 1 },
        .{ .field_indices = &keys },
    );
    defer std.testing.allocator.free(distinct.values);
    try std.testing.expectEqualDeep(&[_]execution.Value{ low, high }, distinct.values);
}

fn distinctCount(values: []execution.Value) !usize {
    var keys = [_]u16{0};
    const distinct = try distinctTable(
        std.testing.allocator,
        .{ .values = values, .width = 1 },
        .{ .field_indices = &keys },
    );
    defer std.testing.allocator.free(distinct.values);
    return distinct.values.len;
}

test "mixed integer and float comparisons stay exact and transitive beyond float precision" {
    const boundary: i64 = 9_007_199_254_740_992;
    const low: execution.Value = .{ .integer = boundary };
    const float_low: execution.Value = .{ .float = @floatFromInt(boundary) };
    const high: execution.Value = .{ .integer = boundary + 1 };
    try std.testing.expect(valuesEqual(low, float_low, false));
    try std.testing.expect(!valuesEqual(high, float_low, false));
    try std.testing.expect(!valuesEqual(float_low, high, false));
    try std.testing.expectEqual(std.math.Order.eq, value_module.order(low, float_low));
    try std.testing.expectEqual(std.math.Order.lt, value_module.order(float_low, high));
    try std.testing.expectEqual(std.math.Order.gt, value_module.order(high, float_low));
    const orders = [_][3]execution.Value{
        .{ low, float_low, high },
        .{ float_low, low, high },
        .{ high, float_low, low },
        .{ high, low, float_low },
        .{ low, high, float_low },
        .{ float_low, high, low },
    };
    var sort_keys = [_]plan.SortKey{
        .{ .field_index = 0, .direction = .ascending, .nulls = .last },
    };
    for (orders) |order| {
        var values = order;
        try std.testing.expectEqual(@as(usize, 2), try distinctCount(&values));
        const input = Table{ .values = &values, .width = 1 };
        try std.testing.expect(hasTotalSortOrder(input, &sort_keys));
        for ([_]usize{ 0, 1, 2, 3 }) |limit| try expectGraphTopK(input, &sort_keys, limit);
    }
}

test "numeric equality and hashing agree for signed zero" {
    var values = [_]execution.Value{
        .{ .float = -0.0 },
        .{ .integer = 0 },
        .{ .float = 0.0 },
    };
    try std.testing.expectEqual(@as(usize, 1), try distinctCount(&values));
}

test "graph comparisons stay defined for NaN" {
    const nan: execution.Value = .{ .float = std.math.nan(f64) };
    try std.testing.expect(!valuesEqual(nan, nan, false));
    try std.testing.expect(!valuesEqual(nan, .{ .integer = 1 }, false));
    try std.testing.expect(!valuesEqual(.{ .integer = 1 }, nan, false));
    try std.testing.expect(!valueMatches(nan, .{ .integer = 1 }, .less_or_equal, false));
    try std.testing.expect(!valueMatches(nan, .{ .integer = 1 }, .greater_or_equal, false));
    var values = [_]execution.Value{ nan, .{ .integer = 3 }, nan };
    try std.testing.expectEqual(@as(usize, 3), try distinctCount(&values));
    var keys = [_]plan.SortKey{
        .{ .field_index = 0, .direction = .ascending, .nulls = .last },
    };
    var mixed = [_]execution.Value{ nan, .{ .integer = 3 }, .null, .{ .float = 1.5 }, nan };
    for ([_]plan.SortDirection{ .ascending, .descending }) |direction| {
        keys[0].direction = direction;
        const input = Table{ .values = &mixed, .width = 1 };
        for (0..mixed.len + 1) |limit| try expectGraphTopK(input, &keys, limit);
    }
}

test "reachability skips identity-less nodes" {
    var node_name = "node".*;
    var parent_name = "parent".*;
    var seed_name = "seed".*;
    var reachable_name = "reachable".*;
    var input_columns = [_]plan.Column{
        .{ .name = &node_name, .kind = .string, .nullable = true },
        .{ .name = &parent_name, .kind = .string, .nullable = true },
        .{ .name = &seed_name, .kind = .boolean, .nullable = false },
    };
    var output_columns = [_]plan.Column{
        .{ .name = &node_name, .kind = .string, .nullable = true },
        .{ .name = &reachable_name, .kind = .boolean, .nullable = false },
    };
    const input_schema = plan.Schema{ .columns = &input_columns };
    var values = [_]execution.Value{
        .{ .string = "root" },  .null,                 .{ .boolean = true },
        .null,                  .{ .string = "root" }, .{ .boolean = false },
        .{ .string = "child" }, .{ .string = "root" }, .{ .boolean = false },
    };
    const output = try reachabilityTable(
        std.testing.allocator,
        .{ .values = &values, .width = 3 },
        &input_schema,
        .{ .columns = &output_columns },
        \\{"keys":{"node":"node","parent":"parent","seed":"seed","direction":"descendants"},
        \\ "fields":[{"field":"node"},{"meta":"reachable"}]}
    ,
        graph_test_definition.bounds,
    );
    defer std.testing.allocator.free(output.values);
    try std.testing.expectEqualDeep(&[_]execution.Value{
        .{ .string = "root" },  .{ .boolean = true },
        .null,                  .{ .boolean = false },
        .{ .string = "child" }, .{ .boolean = true },
    }, output.values);
}

test "reachability links no identity-less seed or descendant" {
    var node_name = "node".*;
    var parent_name = "parent".*;
    var seed_name = "seed".*;
    var reachable_name = "reachable".*;
    var depth_name = "depth".*;
    var input_columns = [_]plan.Column{
        .{ .name = &node_name, .kind = .string, .nullable = true },
        .{ .name = &parent_name, .kind = .string, .nullable = true },
        .{ .name = &seed_name, .kind = .boolean, .nullable = false },
    };
    var seeded_columns = [_]plan.Column{
        .{ .name = &node_name, .kind = .string, .nullable = true },
        .{ .name = &reachable_name, .kind = .boolean, .nullable = false },
    };
    var closure_columns = [_]plan.Column{
        .{ .name = &node_name, .kind = .string, .nullable = true },
        .{ .name = &parent_name, .kind = .string, .nullable = true },
        .{ .name = &depth_name, .kind = .integer, .nullable = false },
    };
    const input_schema = plan.Schema{ .columns = &input_columns };
    var values = [_]execution.Value{
        .{ .string = "root" },  .null,                  .{ .boolean = false },
        .{ .string = "child" }, .{ .string = "root" },  .{ .boolean = false },
        .null,                  .{ .string = "child" }, .{ .boolean = true },
    };
    const input: Table = .{ .values = &values, .width = 3 };
    const seeded = try reachabilityTable(
        std.testing.allocator,
        input,
        &input_schema,
        .{ .columns = &seeded_columns },
        \\{"keys":{"node":"node","parent":"parent","seed":"seed","direction":"ancestors"},
        \\ "fields":[{"field":"node"},{"meta":"reachable"}]}
    ,
        graph_test_definition.bounds,
    );
    defer std.testing.allocator.free(seeded.values);
    try std.testing.expectEqualDeep(&[_]execution.Value{
        .{ .string = "root" },  .{ .boolean = false },
        .{ .string = "child" }, .{ .boolean = false },
        .null,                  .{ .boolean = true },
    }, seeded.values);
    const closure = try reachabilityTable(
        std.testing.allocator,
        input,
        &input_schema,
        .{ .columns = &closure_columns },
        \\{"keys":{"node":"node","parent":"parent","mode":"closure"},
        \\ "fields":[{"meta":"descendant"},{"meta":"ancestor"},{"meta":"depth"}]}
    ,
        graph_test_definition.bounds,
    );
    defer std.testing.allocator.free(closure.values);
    try std.testing.expectEqualDeep(&[_]execution.Value{
        .{ .string = "child" }, .{ .string = "root" }, .{ .integer = 1 },
    }, closure.values);
}

test "graph sorting places nulls by position in both directions" {
    var values = [_]execution.Value{ .null, .{ .integer = 1 }, .null, .{ .integer = 2 } };
    var keys = [_]plan.SortKey{
        .{ .field_index = 0, .direction = .descending, .nulls = .last },
    };
    const input = Table{ .values = &values, .width = 1 };
    const sorted = try sortTable(std.testing.allocator, input, .{ .keys = &keys });
    defer std.testing.allocator.free(sorted.values);
    try std.testing.expectEqualDeep(
        &[_]execution.Value{ .{ .integer = 2 }, .{ .integer = 1 }, .null, .null },
        sorted.values,
    );
    keys[0].nulls = .first;
    const nulls_first = try sortTable(std.testing.allocator, input, .{ .keys = &keys });
    defer std.testing.allocator.free(nulls_first.values);
    try std.testing.expectEqualDeep(
        &[_]execution.Value{ .null, .null, .{ .integer = 2 }, .{ .integer = 1 } },
        nulls_first.values,
    );
    try std.testing.expect(!valueMatches(.null, .{ .integer = 1 }, .less_or_equal, false));
    try std.testing.expect(!valueMatches(.null, .{ .integer = 1 }, .greater_or_equal, false));
}

test "partition ranks order sessions exactly as the fold sort orders their rows" {
    const allocator = std.testing.allocator;
    const sessions = [_]?[]const u8{ "zeta", null, "alpha", null, "mid" };
    const path_ranks = try rankPartitions(allocator, .path, &sessions);
    defer allocator.free(path_ranks);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, path_ranks);
    var values: [sessions.len]execution.Value = undefined;
    for (&values, sessions) |*value, session| {
        value.* = if (session) |text| .{ .string = text } else .null;
    }
    const input = Table{ .values = &values, .width = 1 };
    for ([_]plan.SortDirection{ .ascending, .descending }) |direction| {
        for ([_]plan.NullOrder{ .first, .last }) |nulls| {
            var keys = [_]plan.SortKey{
                .{ .field_index = 0, .direction = direction, .nulls = nulls },
            };
            const ranks = try rankPartitions(allocator, .{ .session = keys[0] }, &sessions);
            defer allocator.free(ranks);
            const sorted = try sortTable(allocator, input, .{ .keys = &keys });
            defer allocator.free(sorted.values);
            for (ranks, values) |rank, value| {
                try std.testing.expectEqualDeep(value, sorted.values[rank]);
            }
        }
    }
    const ascending = try rankPartitions(
        allocator,
        .{ .session = .{ .field_index = 0, .direction = .ascending, .nulls = .last } },
        &sessions,
    );
    defer allocator.free(ascending);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3, 0, 4, 1 }, ascending);
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
