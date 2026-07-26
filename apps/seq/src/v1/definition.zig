const std = @import("std");
const definition_core = @import("definition_core");
const physical = @import("physical.zig");

pub const schema = "seq-observation-definition/v1";
pub const abi = "seq-observation-abi/v1";

pub const Operator = enum {
    scan,
    project,
    derive,
    filter,
    join,
    group,
    aggregate,
    sort,
    limit,
    top_k,
    distinct,
    union_relations,
    named_relation,
    result_projection,
    literal_match,
    regex_match,
    multi_literal_match,
    json_pointer,
    structured_type,
    evidence_classify,
    partition,
    ordered_fold,
    temporal_correlate,
    reachability,

    pub fn id(self: Operator) []const u8 {
        return switch (self) {
            .top_k => "top-k",
            .union_relations => "union",
            .named_relation => "named-relation",
            .result_projection => "result-projection",
            .literal_match => "literal-match",
            .regex_match => "regex-match",
            .multi_literal_match => "multi-literal-match",
            .json_pointer => "json-pointer",
            .structured_type => "structured-type",
            .evidence_classify => "evidence-classify",
            .ordered_fold => "ordered-fold",
            .temporal_correlate => "temporal-correlate",
            else => @tagName(self),
        };
    }

    pub fn parse(text: []const u8) !Operator {
        inline for (@typeInfo(Operator).@"enum".fields) |field| {
            const value: Operator = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, value.id())) return value;
        }
        return error.UnsupportedObservationOperator;
    }

    pub fn version(_: Operator) u16 {
        return 1;
    }
};

pub const Selector = enum {
    root,
    session_id,
    path,
    repo,
    since,
    until,
    last,

    pub fn id(self: Selector) []const u8 {
        return switch (self) {
            .session_id => "session-id",
            else => @tagName(self),
        };
    }

    fn parse(text: []const u8) !Selector {
        inline for (@typeInfo(Selector).@"enum".fields) |field| {
            const value: Selector = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, value.id())) return value;
        }
        return error.UnsupportedSelector;
    }
};

pub const Renderer = enum {
    text,
    table,
    csv,
    json,
    jsonl,
    markdown,
    dot,

    pub fn parse(text: []const u8) !Renderer {
        inline for (@typeInfo(Renderer).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return error.UnsupportedRenderer;
    }
};

pub const ExternalScalarKind = enum {
    string,
    integer,
    float,
    boolean,
    json,

    fn parse(text: []const u8) !ExternalScalarKind {
        inline for (@typeInfo(ExternalScalarKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidExternalFieldType;
    }
};

pub const RelationRequirement = struct {
    relation: physical.Relation,
    fields: []u16,

    fn deinit(self: *RelationRequirement, allocator: std.mem.Allocator) void {
        allocator.free(self.fields);
        self.* = undefined;
    }
};

pub const ExternalField = struct {
    name: []u8,
    kind: ExternalScalarKind,
    nullable: bool,

    fn deinit(self: *ExternalField, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const ExternalInput = struct {
    name: []u8,
    schema_id: []u8,
    digest: ?[]u8,
    fields: []ExternalField,
    max_rows: usize,
    max_bytes: usize,

    fn deinit(self: *ExternalInput, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.schema_id);
        if (self.digest) |value| allocator.free(value);
        for (self.fields) |*field| field.deinit(allocator);
        allocator.free(self.fields);
        self.* = undefined;
    }
};

pub const Step = struct {
    operator: Operator,
    output_name: ?[]u8,
    input_names: [][]u8,
    canonical_config: []u8,

    fn deinit(self: *Step, allocator: std.mem.Allocator) void {
        if (self.output_name) |value| allocator.free(value);
        for (self.input_names) |value| allocator.free(value);
        allocator.free(self.input_names);
        allocator.free(self.canonical_config);
        self.* = undefined;
    }
};

pub const Projection = struct {
    name: []u8,
    relation: []u8,
    schema_id: []u8,
    fields: [][]u8,
    renderer_mask: u8,

    fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.relation);
        allocator.free(self.schema_id);
        for (self.fields) |field| allocator.free(field);
        allocator.free(self.fields);
        self.* = undefined;
    }
};

pub const Bounds = struct {
    max_rows: usize,
    max_output_bytes: usize,
    max_fold_states: usize,
    max_input_bytes: usize,
    max_graph_depth: usize,
    max_graph_nodes: usize,
    max_diagnostics: usize,
};

pub const Plan = struct {
    id: []u8,
    closure_digest: [71]u8,
    operator_mask: u32,
    parameter_declarations: definition_core.parameters.Declarations,
    selector_mask: u8,
    relations: []RelationRequirement,
    inputs: []ExternalInput,
    steps: []Step,
    projections: []Projection,
    bounds: Bounds,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        self.parameter_declarations.deinit(allocator);
        for (self.relations) |*relation| relation.deinit(allocator);
        allocator.free(self.relations);
        for (self.inputs) |*input| input.deinit(allocator);
        allocator.free(self.inputs);
        for (self.steps) |*step| step.deinit(allocator);
        allocator.free(self.steps);
        for (self.projections) |*projection| projection.deinit(allocator);
        allocator.free(self.projections);
        self.* = undefined;
    }

    pub fn requires(self: Plan, operator: Operator) bool {
        return (self.operator_mask & operatorBit(operator)) != 0;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    closure: *const definition_core.Closure,
    entry_path: []const u8,
) !Plan {
    const entry = closure.find(entry_path) orelse return error.EntryDefinitionMissing;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        entry.canonical_json,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    defer parsed.deinit();
    const root = try definition_core.json.object(parsed.value);
    try definition_core.json.requireExactKeys(root, &.{
        "schema",
        "id",
        "imports",
        "requires",
        "parameters",
        "selectors",
        "relations",
        "inputs",
        "pipeline",
        "projections",
        "bounds",
    });
    try definition_core.json.requireFields(root, &.{
        "schema",
        "id",
        "requires",
        "selectors",
        "relations",
        "inputs",
        "pipeline",
        "projections",
        "bounds",
    });
    if (!std.mem.eql(
        u8,
        try definition_core.json.requiredString(root, "schema"),
        schema,
    )) return error.InvalidObservationDefinitionSchema;
    const id = try definition_core.json.requiredString(root, "id");
    try definition_core.json.safeIdentifier(id, 256);

    const operator_mask = try parseRequires(try definition_core.json.object(
        try definition_core.json.field(root, "requires"),
    ));
    var parameter_declarations = try definition_core.parameters.compile(
        allocator,
        root.get("parameters"),
    );
    errdefer parameter_declarations.deinit(allocator);
    const selector_mask = try parseSelectors(try definition_core.json.array(
        try definition_core.json.field(root, "selectors"),
    ));
    const relations = try parseRelations(
        allocator,
        try definition_core.json.array(try definition_core.json.field(root, "relations")),
    );
    errdefer deinitRelations(allocator, relations);
    const inputs = try parseInputs(
        allocator,
        try definition_core.json.array(try definition_core.json.field(root, "inputs")),
    );
    errdefer deinitInputs(allocator, inputs);
    const steps = try parseSteps(
        allocator,
        try definition_core.json.array(try definition_core.json.field(root, "pipeline")),
        operator_mask,
        relations,
        inputs,
    );
    errdefer deinitSteps(allocator, steps);
    const projections = try parseProjections(
        allocator,
        try definition_core.json.object(try definition_core.json.field(root, "projections")),
        steps,
    );
    errdefer deinitProjections(allocator, projections);
    const bounds = try parseBounds(try definition_core.json.object(
        try definition_core.json.field(root, "bounds"),
    ));

    return .{
        .id = try allocator.dupe(u8, id),
        .closure_digest = closure.digest,
        .operator_mask = operator_mask,
        .parameter_declarations = parameter_declarations,
        .selector_mask = selector_mask,
        .relations = relations,
        .inputs = inputs,
        .steps = steps,
        .projections = projections,
        .bounds = bounds,
    };
}

fn parseRequires(object: std.json.ObjectMap) !u32 {
    try definition_core.json.requireExactKeys(object, &.{ "abi", "operators" });
    try definition_core.json.requireFields(object, &.{ "abi", "operators" });
    if (!std.mem.eql(
        u8,
        try definition_core.json.requiredString(object, "abi"),
        abi,
    )) return error.IncompatibleObservationAbi;
    const items = try definition_core.json.array(
        try definition_core.json.field(object, "operators"),
    );
    var mask: u32 = 0;
    for (items.items) |item| {
        const operator = try Operator.parse(try definition_core.json.string(item));
        const bit = operatorBit(operator);
        if ((mask & bit) != 0) return error.DuplicateObservationOperator;
        mask |= bit;
    }
    return mask;
}

fn parseSelectors(items: std.json.Array) !u8 {
    var mask: u8 = 0;
    for (items.items) |item| {
        const selector = try Selector.parse(try definition_core.json.string(item));
        const bit: u8 = @as(u8, 1) << @intCast(@intFromEnum(selector));
        if ((mask & bit) != 0) return error.DuplicateSelector;
        mask |= bit;
    }
    return mask;
}

fn parseRelations(
    allocator: std.mem.Allocator,
    items: std.json.Array,
) ![]RelationRequirement {
    var out: std.ArrayList(RelationRequirement) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    for (items.items) |item| {
        const object = try definition_core.json.object(item);
        try definition_core.json.requireExactKeys(object, &.{ "name", "fields" });
        try definition_core.json.requireFields(object, &.{ "name", "fields" });
        const relation = try physical.Relation.parse(
            try definition_core.json.requiredString(object, "name"),
        );
        for (out.items) |prior| if (prior.relation == relation) {
            return error.DuplicatePhysicalRelation;
        };
        const field_values = try definition_core.json.array(
            try definition_core.json.field(object, "fields"),
        );
        if (field_values.items.len == 0) return error.EmptyPhysicalFieldSet;
        const fields = try allocator.alloc(u16, field_values.items.len);
        errdefer allocator.free(fields);
        for (field_values.items, 0..) |field_value, index| {
            fields[index] = try relation.fieldIndex(
                try definition_core.json.string(field_value),
            );
            for (fields[0..index]) |prior| if (prior == fields[index]) {
                return error.DuplicatePhysicalField;
            };
        }
        std.mem.sort(u16, fields, {}, std.sort.asc(u16));
        try out.append(allocator, .{ .relation = relation, .fields = fields });
    }
    std.mem.sort(RelationRequirement, out.items, {}, struct {
        fn lessThan(_: void, left: RelationRequirement, right: RelationRequirement) bool {
            return @intFromEnum(left.relation) < @intFromEnum(right.relation);
        }
    }.lessThan);
    return out.toOwnedSlice(allocator);
}

fn parseInputs(
    allocator: std.mem.Allocator,
    items: std.json.Array,
) ![]ExternalInput {
    var out: std.ArrayList(ExternalInput) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    for (items.items) |item| {
        const object = try definition_core.json.object(item);
        try definition_core.json.requireExactKeys(object, &.{
            "name", "schema", "digest", "fields", "max_rows", "max_bytes",
        });
        try definition_core.json.requireFields(object, &.{
            "name", "schema", "fields", "max_rows", "max_bytes",
        });
        const name = try definition_core.json.requiredString(object, "name");
        try definition_core.json.safeIdentifier(name, 128);
        for (out.items) |prior| if (std.mem.eql(u8, prior.name, name)) {
            return error.DuplicateExternalInput;
        };
        const schema_id = try definition_core.json.requiredString(object, "schema");
        try definition_core.json.safeIdentifier(schema_id, 256);
        const digest = try definition_core.json.optionalString(object, "digest");
        if (digest) |value| try definition_core.json.digest(value);
        const fields = try parseExternalFields(
            allocator,
            try definition_core.json.array(try definition_core.json.field(object, "fields")),
        );
        errdefer deinitExternalFields(allocator, fields);
        const max_rows = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_rows"),
        );
        const max_bytes = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_bytes"),
        );
        if (max_rows == 0 or max_rows > 1_000_000 or
            max_bytes == 0 or max_bytes > 256 * 1024 * 1024)
        {
            return error.ExternalInputBoundsExceeded;
        }
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .schema_id = try allocator.dupe(u8, schema_id),
            .digest = if (digest) |value| try allocator.dupe(u8, value) else null,
            .fields = fields,
            .max_rows = max_rows,
            .max_bytes = max_bytes,
        });
    }
    std.mem.sort(ExternalInput, out.items, {}, struct {
        fn lessThan(_: void, left: ExternalInput, right: ExternalInput) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return out.toOwnedSlice(allocator);
}

fn parseExternalFields(
    allocator: std.mem.Allocator,
    items: std.json.Array,
) ![]ExternalField {
    if (items.items.len == 0 or items.items.len > 256) {
        return error.InvalidExternalFieldCount;
    }
    const fields = try allocator.alloc(ExternalField, items.items.len);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (items.items, 0..) |item, index| {
        const object = try definition_core.json.object(item);
        try definition_core.json.requireExactKeys(object, &.{ "name", "type", "nullable" });
        try definition_core.json.requireFields(object, &.{ "name", "type" });
        const name = try definition_core.json.requiredString(object, "name");
        try definition_core.json.safeIdentifier(name, 128);
        for (fields[0..index]) |prior| if (std.mem.eql(u8, prior.name, name)) {
            return error.DuplicateExternalField;
        };
        fields[index] = .{
            .name = try allocator.dupe(u8, name),
            .kind = try ExternalScalarKind.parse(
                try definition_core.json.requiredString(object, "type"),
            ),
            .nullable = if (object.get("nullable")) |raw|
                try definition_core.json.boolean(raw)
            else
                true,
        };
        initialized += 1;
    }
    return fields;
}

fn parseSteps(
    allocator: std.mem.Allocator,
    items: std.json.Array,
    operator_mask: u32,
    relations: []const RelationRequirement,
    inputs: []const ExternalInput,
) ![]Step {
    if (items.items.len == 0 or items.items.len > 256) {
        return error.InvalidPipelineLength;
    }
    var out: std.ArrayList(Step) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    for (items.items) |item| {
        const object = try definition_core.json.object(item);
        try definition_core.json.requireExactKeys(object, &.{
            "op", "input", "inputs", "as", "name", "relation", "fields", "where",
            "on", "keys", "metrics", "by", "limit", "depth", "max_nodes", "state",
            "order_by", "transitions", "emit", "window", "classifications",
        });
        const operator = try Operator.parse(try definition_core.json.requiredString(object, "op"));
        if ((operator_mask & operatorBit(operator)) == 0) {
            return error.UndeclaredObservationOperator;
        }
        try validateStepShape(operator, object);
        if (operator == .scan) {
            const relation = try physical.Relation.parse(
                try definition_core.json.requiredString(object, "relation"),
            );
            var declared = false;
            for (relations) |requirement| if (requirement.relation == relation) {
                declared = true;
                break;
            };
            if (!declared) return error.UndeclaredPhysicalRelation;
        }
        const output_name = try stepOutputName(operator, object);
        if (output_name) |name| {
            try definition_core.json.safeIdentifier(name, 128);
            if (relationNameExists(out.items, inputs, relations, name)) {
                return error.DuplicatePipelineRelation;
            }
        }
        const input_names = try parseStepInputs(allocator, operator, object);
        errdefer {
            for (input_names) |name| allocator.free(name);
            allocator.free(input_names);
        }
        for (input_names) |name| {
            if (!relationNameExists(out.items, inputs, relations, name)) {
                return error.UnknownPipelineInput;
            }
        }
        const canonical_config = try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            item,
        );
        errdefer allocator.free(canonical_config);
        try out.append(allocator, .{
            .operator = operator,
            .output_name = if (output_name) |name| try allocator.dupe(u8, name) else null,
            .input_names = input_names,
            .canonical_config = canonical_config,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn validateStepShape(operator: Operator, object: std.json.ObjectMap) !void {
    switch (operator) {
        .scan => try definition_core.json.requireFields(object, &.{ "op", "relation", "as" }),
        .join, .union_relations, .temporal_correlate => try definition_core.json.requireFields(
            object,
            &.{ "op", "inputs", "as" },
        ),
        .named_relation, .result_projection => try definition_core.json.requireFields(
            object,
            &.{ "op", "input", "name" },
        ),
        .literal_match,
        .regex_match,
        .multi_literal_match,
        .json_pointer,
        .structured_type,
        .evidence_classify,
        => return error.ExpressionOperatorCannotBePipelineStep,
        else => try definition_core.json.requireFields(object, &.{ "op", "input", "as" }),
    }
}

fn stepOutputName(operator: Operator, object: std.json.ObjectMap) !?[]const u8 {
    return switch (operator) {
        .named_relation, .result_projection => try definition_core.json.requiredString(object, "name"),
        .literal_match,
        .regex_match,
        .multi_literal_match,
        .json_pointer,
        .structured_type,
        .evidence_classify,
        => null,
        else => try definition_core.json.requiredString(object, "as"),
    };
}

fn parseStepInputs(
    allocator: std.mem.Allocator,
    operator: Operator,
    object: std.json.ObjectMap,
) ![][]u8 {
    switch (operator) {
        .scan => return allocator.alloc([]u8, 0),
        .join, .union_relations, .temporal_correlate => {
            const values = try definition_core.json.array(
                try definition_core.json.field(object, "inputs"),
            );
            if (values.items.len < 2 or values.items.len > 16) {
                return error.InvalidPipelineInputCount;
            }
            const out = try allocator.alloc([]u8, values.items.len);
            var initialized: usize = 0;
            errdefer {
                for (out[0..initialized]) |name| allocator.free(name);
                allocator.free(out);
            }
            for (values.items, 0..) |value, index| {
                const name = try definition_core.json.string(value);
                try definition_core.json.safeIdentifier(name, 128);
                out[index] = try allocator.dupe(u8, name);
                initialized += 1;
            }
            return out;
        },
        else => {
            const out = try allocator.alloc([]u8, 1);
            errdefer allocator.free(out);
            const name = try definition_core.json.requiredString(object, "input");
            try definition_core.json.safeIdentifier(name, 128);
            out[0] = try allocator.dupe(u8, name);
            return out;
        },
    }
}

fn relationNameExists(
    steps: []const Step,
    inputs: []const ExternalInput,
    relations: []const RelationRequirement,
    name: []const u8,
) bool {
    for (steps) |step| if (step.output_name) |output| {
        if (std.mem.eql(u8, output, name)) return true;
    };
    for (inputs) |input| if (std.mem.eql(u8, input.name, name)) return true;
    if (physical.Relation.parse(name)) |relation| {
        for (relations) |requirement| if (requirement.relation == relation) return true;
    } else |_| {}
    return false;
}

fn parseProjections(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    steps: []const Step,
) ![]Projection {
    if (object.count() == 0 or object.count() > 64) return error.InvalidProjectionCount;
    var out: std.ArrayList(Projection) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try definition_core.json.safeIdentifier(entry.key_ptr.*, 128);
        const projection = try definition_core.json.object(entry.value_ptr.*);
        try definition_core.json.requireExactKeys(projection, &.{
            "relation", "schema", "fields", "renderers",
        });
        try definition_core.json.requireFields(projection, &.{
            "relation", "schema", "fields", "renderers",
        });
        const relation = try definition_core.json.requiredString(projection, "relation");
        var found = false;
        for (steps) |step| if (step.output_name) |output| {
            if (std.mem.eql(u8, output, relation)) {
                found = true;
                break;
            }
        };
        if (!found) return error.UnknownProjectionRelation;
        const schema_id = try definition_core.json.requiredString(projection, "schema");
        try definition_core.json.safeIdentifier(schema_id, 256);
        const fields = try parseOwnedStringArray(
            allocator,
            try definition_core.json.array(try definition_core.json.field(projection, "fields")),
            1,
            256,
        );
        errdefer deinitStrings(allocator, fields);
        const renderer_mask = try parseRenderers(try definition_core.json.array(
            try definition_core.json.field(projection, "renderers"),
        ));
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .relation = try allocator.dupe(u8, relation),
            .schema_id = try allocator.dupe(u8, schema_id),
            .fields = fields,
            .renderer_mask = renderer_mask,
        });
    }
    std.mem.sort(Projection, out.items, {}, struct {
        fn lessThan(_: void, left: Projection, right: Projection) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return out.toOwnedSlice(allocator);
}

fn parseRenderers(items: std.json.Array) !u8 {
    if (items.items.len == 0) return error.EmptyRendererSet;
    var mask: u8 = 0;
    for (items.items) |item| {
        const renderer = try Renderer.parse(try definition_core.json.string(item));
        const bit: u8 = @as(u8, 1) << @intCast(@intFromEnum(renderer));
        if ((mask & bit) != 0) return error.DuplicateRenderer;
        mask |= bit;
    }
    return mask;
}

fn parseBounds(object: std.json.ObjectMap) !Bounds {
    try definition_core.json.requireExactKeys(object, &.{
        "max_rows",
        "max_output_bytes",
        "max_fold_states",
        "max_input_bytes",
        "max_graph_depth",
        "max_graph_nodes",
        "max_diagnostics",
    });
    try definition_core.json.requireFields(object, &.{
        "max_rows",
        "max_output_bytes",
        "max_fold_states",
    });
    const bounds: Bounds = .{
        .max_rows = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_rows"),
        ),
        .max_output_bytes = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_output_bytes"),
        ),
        .max_fold_states = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_fold_states"),
        ),
        .max_input_bytes = if (object.get("max_input_bytes")) |value|
            try definition_core.json.unsigned(value)
        else
            256 * 1024 * 1024,
        .max_graph_depth = if (object.get("max_graph_depth")) |value|
            try definition_core.json.unsigned(value)
        else
            64,
        .max_graph_nodes = if (object.get("max_graph_nodes")) |value|
            try definition_core.json.unsigned(value)
        else
            100_000,
        .max_diagnostics = if (object.get("max_diagnostics")) |value|
            try definition_core.json.unsigned(value)
        else
            64,
    };
    if (bounds.max_rows == 0 or bounds.max_rows > 10_000_000 or
        bounds.max_output_bytes == 0 or bounds.max_output_bytes > 256 * 1024 * 1024 or
        bounds.max_fold_states == 0 or bounds.max_fold_states > 65_536 or
        bounds.max_input_bytes == 0 or bounds.max_input_bytes > 4 * 1024 * 1024 * 1024 or
        bounds.max_graph_depth == 0 or bounds.max_graph_depth > 256 or
        bounds.max_graph_nodes == 0 or bounds.max_graph_nodes > 1_000_000 or
        bounds.max_diagnostics == 0 or bounds.max_diagnostics > 1024)
    {
        return error.ObservationBoundsExceeded;
    }
    return bounds;
}

fn parseOwnedStringArray(
    allocator: std.mem.Allocator,
    items: std.json.Array,
    min_count: usize,
    max_count: usize,
) ![][]u8 {
    if (items.items.len < min_count or items.items.len > max_count) {
        return error.InvalidStringArrayLength;
    }
    const out = try allocator.alloc([]u8, items.items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (items.items, 0..) |item, index| {
        const text = try definition_core.json.string(item);
        try definition_core.json.safeIdentifier(text, 128);
        for (out[0..index]) |prior| if (std.mem.eql(u8, prior, text)) {
            return error.DuplicateString;
        };
        out[index] = try allocator.dupe(u8, text);
        initialized += 1;
    }
    return out;
}

fn operatorBit(operator: Operator) u32 {
    return @as(u32, 1) << @intCast(@intFromEnum(operator));
}

fn deinitRelations(allocator: std.mem.Allocator, items: []RelationRequirement) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitExternalFields(allocator: std.mem.Allocator, fields: []ExternalField) void {
    for (fields) |*field| field.deinit(allocator);
    allocator.free(fields);
}

fn deinitInputs(allocator: std.mem.Allocator, items: []ExternalInput) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitSteps(allocator: std.mem.Allocator, items: []Step) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitStrings(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn deinitProjections(allocator: std.mem.Allocator, items: []Projection) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

test "observation definition compiles passive structure into an immutable plan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data =
        \\{
        \\  "schema":"seq-observation-definition/v1",
        \\  "id":"example/messages",
        \\  "requires":{"abi":"seq-observation-abi/v1","operators":["scan","filter","project"]},
        \\  "parameters":{"needle":{"type":"string","required":true}},
        \\  "selectors":["root","session-id","since","until"],
        \\  "relations":[{"name":"messages","fields":["session_id","turn_index","role","text","timestamp","source_event_id","path","private"]}],
        \\  "inputs":[],
        \\  "pipeline":[
        \\    {"op":"scan","relation":"messages","as":"source"},
        \\    {"op":"filter","input":"source","as":"matched","where":[{"field":"text","op":"contains","param":"needle"}]},
        \\    {"op":"project","input":"matched","as":"rows","fields":["session_id","turn_index","role","text"]}
        \\  ],
        \\  "projections":{"rows":{"relation":"rows","schema":"example-message-rows/v1","fields":["session_id","turn_index","role","text"],"renderers":["json","jsonl","table"]}},
        \\  "bounds":{"max_rows":100000,"max_output_bytes":16777216,"max_fold_states":256}
        \\}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "observation.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var plan = try compile(std.testing.allocator, &closure, "observation.json");
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("example/messages", plan.id);
    try std.testing.expect(plan.requires(.scan));
    try std.testing.expectEqual(@as(usize, 3), plan.steps.len);
    try std.testing.expectEqual(@as(usize, 1), plan.projections.len);
    const authority_boundary: definition_core.result.AuthorityBoundary = .{};
    try std.testing.expect(!authority_boundary.authority_granted);
}

test "observation definition rejects undeclared operators and domain relations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "invalid.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/invalid","requires":{"abi":"seq-observation-abi/v1","operators":["scan"]},"selectors":[],"relations":[{"name":"messages","fields":["text"]}],"inputs":[],"pipeline":[{"op":"scan","relation":"messages","as":"source"},{"op":"filter","input":"source","as":"rows","where":[]}],"projections":{"rows":{"relation":"rows","schema":"rows/v1","fields":["text"],"renderers":["json"]}},"bounds":{"max_rows":10,"max_output_bytes":1024,"max_fold_states":1}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "invalid.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UndeclaredObservationOperator,
        compile(std.testing.allocator, &closure, "invalid.json"),
    );
    try std.testing.expectError(
        error.UnknownPhysicalRelation,
        physical.Relation.parse("approval_events"),
    );
}
