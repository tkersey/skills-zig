const std = @import("std");
const definition_core = @import("definition_core");
const plan = @import("plan.zig");
const seq_time = @import("seq_time");
const value_module = @import("value.zig");
const Value = value_module.Value;

pub const RuntimeSelectors = struct {
    path: ?[]const u8 = null,
    root: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
};

pub const Derivation = struct {
    parsed: std.json.Parsed(std.json.Value),
    arena: std.heap.ArenaAllocator,
    expressions: []*CompiledExpr,
    input_schema: *const plan.Schema,
    preserve_input: bool,
    output_width: usize,
    config_bytes: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        input_schema: *const plan.Schema,
        output_schema: *const plan.Schema,
        config: []const u8,
    ) !Derivation {
        var parsed = try parseConfig(allocator, config);
        errdefer parsed.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
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
        const expressions = try arena.allocator().alloc(*CompiledExpr, fields.items.len);
        for (fields.items, 0..) |field, index| {
            const object = try definition_core.json.object(field);
            expressions[index] = try compileExpr(
                arena.allocator(),
                try definition_core.json.field(object, "expr"),
                input_schema,
                if (sequential) output_schema else null,
                index,
            );
        }
        return .{
            .parsed = parsed,
            .arena = arena,
            .expressions = expressions,
            .input_schema = input_schema,
            .preserve_input = preserve_input,
            .output_width = output_schema.columns.len,
            .config_bytes = config.len,
        };
    }

    pub fn deinit(self: *Derivation) void {
        self.arena.deinit();
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn apply(
        self: *const Derivation,
        workspace: *ExpressionWorkspace,
        allocator: std.mem.Allocator,
        bindings: *const definition_core.parameters.Bindings,
        selectors: RuntimeSelectors,
        row: []const Value,
        output: []Value,
    ) !void {
        std.debug.assert(output.len == self.output_width);
        if (self.preserve_input) @memcpy(output[0..row.len], row);
        for (self.expressions, 0..) |expression, index| {
            output[(if (self.preserve_input) row.len else 0) + index] = try evalCompiledExpr(
                workspace,
                allocator,
                expression,
                row,
                output,
                self.input_schema,
                bindings,
                selectors,
            );
        }
    }
};

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
    text_prefix,
};

pub const CompiledExpr = union(enum) {
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

pub fn compileExpr(
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
    if (std.mem.eql(u8, op, "text-prefix")) return .text_prefix;
    return null;
}

pub fn evalCompiledExpr(
    workspace: *ExpressionWorkspace,
    allocator: std.mem.Allocator,
    expression: *const CompiledExpr,
    row: []const Value,
    output: []const Value,
    schema: *const plan.Schema,
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
) !Value {
    return workspace.evaluate(.{ .compiled = expression }, .{
        .allocator = allocator,
        .row = row,
        .output = output,
        .schema = schema,
        .bindings = bindings,
        .selectors = selectors,
    });
}

pub const ExpressionContext = struct {
    allocator: std.mem.Allocator,
    row: []const Value,
    output: []const Value = &.{},
    schema: *const plan.Schema,
    state: []const Value = &.{},
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
    value: Value,
    branch: ExpressionBranch,
};

pub const ExpressionNode = union(enum) {
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
        .text_prefix => "text-prefix",
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
    left: Value = .null,
    text: std.ArrayList(u8) = .empty,

    fn accept(
        self: *ExpressionFrame,
        value: *Value,
        scratch_allocator: std.mem.Allocator,
        retained_allocator: std.mem.Allocator,
        text_budget: *ExpressionTextBudget,
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
                try text_budget.append(&self.text, scratch_allocator, valueText(value.*) orelse "");
                self.next += 1;
                if (self.next < self.branch.count) return false;
                value.* = .{ .string = try retained_allocator.dupe(u8, self.text.items) };
            },
        }
        return true;
    }
};

const ExpressionTextBudget = struct {
    max_bytes: ?usize = null,
    bytes: usize = 0,

    fn append(
        self: *ExpressionTextBudget,
        buffer: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        text: []const u8,
    ) !void {
        const prior_capacity = buffer.capacity;
        if (self.max_bytes) |bound| {
            const size = std.math.add(usize, buffer.items.len, text.len) catch
                return error.ObservationExpressionByteBoundExceeded;
            if (size -| prior_capacity > bound -| self.bytes) {
                return error.ObservationExpressionByteBoundExceeded;
            }
            try buffer.ensureTotalCapacityPrecise(allocator, size);
            buffer.appendSliceAssumeCapacity(text);
        } else {
            try buffer.appendSlice(allocator, text);
        }
        self.bytes += buffer.capacity - prior_capacity;
    }

    fn release(self: *ExpressionTextBudget, buffer: std.ArrayList(u8)) void {
        self.bytes -= buffer.capacity;
    }
};

pub const ExpressionWorkspace = struct {
    allocator: std.mem.Allocator,
    // Every pending expression consumes at least one byte in this bounded config.
    config_bytes: usize,
    frames: std.ArrayList(ExpressionFrame) = .empty,
    text_budget: ExpressionTextBudget = .{},

    pub fn deinit(self: *ExpressionWorkspace) void {
        std.debug.assert(self.frames.items.len == 0);
        std.debug.assert(self.text_budget.bytes == 0);
        self.frames.deinit(self.allocator);
    }

    pub fn evaluate(
        self: *ExpressionWorkspace,
        root: ExpressionNode,
        context: ExpressionContext,
    ) !Value {
        std.debug.assert(self.frames.items.len == 0);
        std.debug.assert(self.text_budget.bytes == 0);
        defer {
            for (self.frames.items) |*frame| {
                self.text_budget.release(frame.text);
                frame.text.deinit(self.allocator);
            }
            self.frames.clearRetainingCapacity();
        }
        var pending: ?ExpressionNode = root;
        var value: Value = .null;
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
            if (try frame.accept(&value, self.allocator, context.allocator, &self.text_budget)) {
                self.text_budget.release(frame.text);
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

fn unaryExpression(op: []const u8, value: Value) Value {
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
    left: Value,
    right: Value,
) !Value {
    if (parseCompiledOp(op)) |compiled| return compiledBinaryExpression(compiled, left, right);
    return numericOperator(op, left, right);
}

fn compiledBinaryExpression(
    op: CompiledOp,
    left: Value,
    right: Value,
) !Value {
    return switch (op) {
        .eq => .{ .boolean = valuesEqual(left, right, false) },
        .ne => .{ .boolean = !valuesEqual(left, right, false) },
        .lt => .{ .boolean = compareValues(left, right) == .lt },
        .le => .{ .boolean = compareValues(left, right) != .gt },
        .gt => .{ .boolean = compareValues(left, right) == .gt },
        .ge => .{ .boolean = compareValues(left, right) != .lt },
        .and_op => .{ .boolean = truthy(left) and truthy(right) },
        .or_op => .{ .boolean = truthy(left) or truthy(right) },
        .text_prefix => textPrefix(left, right),
        .add, .subtract, .multiply, .divide => numericOperator(@tagName(op), left, right),
    };
}

fn textPrefix(text_value: Value, bound_value: Value) !Value {
    if (bound_value != .integer) return error.ObservationExpressionTypeMismatch;
    const bound = std.math.cast(usize, bound_value.integer) orelse
        return error.InvalidObservationTextBound;
    if (text_value == .null) return .null;
    const text = valueText(text_value) orelse return error.ObservationExpressionTypeMismatch;
    const limit = @min(bound, text.len);
    var end: usize = 0;
    while (end < limit) {
        const width = std.unicode.utf8ByteSequenceLength(text[end]) catch
            return error.InvalidObservationText;
        if (width > limit - end) break;
        _ = std.unicode.utf8Decode(text[end..][0..width]) catch
            return error.InvalidObservationText;
        end += width;
    }
    return .{ .string = text[0..end] };
}

pub fn evalExpr(
    workspace: *ExpressionWorkspace,
    allocator: std.mem.Allocator,
    expression: std.json.Value,
    row: []const Value,
    schema: *const plan.Schema,
    state: []const Value,
    state_names: []const []const u8,
    bindings: *const definition_core.parameters.Bindings,
    selectors: RuntimeSelectors,
) !Value {
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
) !Value {
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
    left: Value,
    right: Value,
) !Value {
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

pub fn scalarValue(value: definition_core.scalar.Value) Value {
    return switch (value) {
        .string, .digest, .timestamp, .safe_identifier, .relative_path => |text| .{
            .string = text,
        },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .boolean = flag },
    };
}

pub fn findName(names: []const []const u8, wanted: []const u8) ?usize {
    for (names, 0..) |name, index| if (std.mem.eql(u8, name, wanted)) return index;
    return null;
}

pub fn truthy(value: Value) bool {
    return switch (value) {
        .boolean => |flag| flag,
        .integer => |number| number != 0,
        .float => |number| number != 0,
        .string => |text| text.len != 0,
        .json => |text| text.len != 0,
        .null => false,
    };
}

pub fn valuesEqual(a: Value, b: Value, ignore_case: bool) bool {
    if (a == .null or b == .null) return a == .null and b == .null;
    if (numericOrder(a, b)) |order| return order == .eq and !isNan(a) and !isNan(b);
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

pub fn compareValues(a: Value, b: Value) std.math.Order {
    if (numericOrder(a, b)) |order| return order;
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

fn numericOrder(a: Value, b: Value) ?std.math.Order {
    return switch (a) {
        .integer => |left| switch (b) {
            .integer => |right| std.math.order(left, right),
            .float => |right| integerFloatOrder(left, right),
            else => null,
        },
        .float => |left| switch (b) {
            .integer => |right| integerFloatOrder(right, left).invert(),
            .float => |right| value_module.compareFloat(left, right),
            else => null,
        },
        else => null,
    };
}

fn integerFloatOrder(integer: i64, float: f64) std.math.Order {
    if (std.math.isNan(float)) return .eq;
    return value_module.compareIntegerFloat(integer, float);
}

fn isNan(value: Value) bool {
    return value == .float and std.math.isNan(value.float);
}

pub fn valueFloat(value: Value) ?f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => null,
    };
}

pub fn valueText(value: Value) ?[]const u8 {
    return switch (value) {
        .string, .json => |text| text,
        else => null,
    };
}

pub fn parseConfig(
    allocator: std.mem.Allocator,
    config: []const u8,
) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, config, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
}

test "native expression text budget bounds live concat frames before allocation" {
    const source =
        "{\"op\":\"concat\",\"args\":[\"12345678\",{\"op\":\"text-prefix\",\"args\":[" ++
        "{\"op\":\"concat\",\"args\":[\"abcd\",\"efgh\"]},1]}]}";
    var parsed = try parseConfig(std.testing.allocator, source);
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema: plan.Schema = .{ .columns = &.{} };
    const bindings: definition_core.parameters.Bindings = .{
        .items = &.{},
        .values_digest = @splat(0),
    };
    const context: ExpressionContext = .{
        .allocator = arena.allocator(),
        .row = &.{},
        .schema = &schema,
        .bindings = &bindings,
        .selectors = .{},
    };
    var workspace: ExpressionWorkspace = .{
        .allocator = std.testing.allocator,
        .config_bytes = source.len,
        .text_budget = .{ .max_bytes = 10 },
    };
    defer workspace.deinit();
    for ([_]bool{ false, true }) |compiled| {
        const node: ExpressionNode = if (compiled)
            .{ .compiled = try compileExpr(arena.allocator(), parsed.value, &schema, null, 0) }
        else
            .{ .dynamic = parsed.value };
        try std.testing.expectError(
            error.ObservationExpressionByteBoundExceeded,
            workspace.evaluate(node, context),
        );
        try std.testing.expectEqual(@as(usize, 0), workspace.text_budget.bytes);
        try std.testing.expectEqual(@as(usize, 0), workspace.frames.items.len);
    }
    const lazy = "{\"op\":\"if\",\"args\":[true,\"ok\",{\"op\":\"concat\",\"args\":[" ++
        "\"12345678\",\"abcdefgh\"]}]}";
    var lazy_parsed = try parseConfig(std.testing.allocator, lazy);
    defer lazy_parsed.deinit();
    const result = try workspace.evaluate(.{ .dynamic = lazy_parsed.value }, context);
    try std.testing.expectEqualStrings("ok", result.string);
}
