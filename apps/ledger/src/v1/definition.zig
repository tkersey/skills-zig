const std = @import("std");
const definition_core = @import("definition_core");

pub const schema = "ledger-artifact-definition/v1";
pub const abi = "ledger-artifact-abi/v1";

pub const Operator = enum {
    exact_object,
    required_field,
    optional_field,
    scalar_type,
    bounded_string,
    bounded_number,
    bounded_array,
    bounded_object,
    enum_value,
    digest,
    timestamp,
    safe_identifier,
    safe_relative_path,
    regex,
    tagged_union,
    one_of,
    unique,
    sorted,
    set_equality,
    subset,
    superset,
    disjoint,
    total_partition,
    exactly_one,
    at_least_one,
    all_rules,
    any_rules,
    no_rules,
    keyed_unique,
    keyed_join,
    reference_exists,
    implies,
    field_equal,
    field_not_equal,
    cross_input_equal,
    predecessor_successor,
    total_mapping,
    canonical_json,
    canonical_text,
    sha256,
    content_address,
    composite_identity,
    timestamp_ordinal,
    path_format,
    set_order,
    immutable_document,
    append_only_log,
    event_envelope,
    sequence,
    previous_digest,
    body_digest,
    event_digest,
    event_kinds,
    transition_table,
    reducer,
    idempotency_key,
    compare_append,
    compare_replace,
    create_new,
    exclusive_custody,
    atomic_transaction,
    replay,
    filter,
    select,
    sort,
    limit,
    id_lookup,
    latest,
    relevance,
    fold,
    @"export",
    text_render,

    pub fn id(self: Operator) []const u8 {
        return switch (self) {
            .exact_object => "exact-object",
            .required_field => "required-field",
            .optional_field => "optional-field",
            .scalar_type => "scalar-type",
            .bounded_string => "bounded-string",
            .bounded_number => "bounded-number",
            .bounded_array => "bounded-array",
            .bounded_object => "bounded-object",
            .enum_value => "enum",
            .safe_identifier => "safe-identifier",
            .safe_relative_path => "safe-relative-path",
            .tagged_union => "tagged-union",
            .one_of => "one-of",
            .set_equality => "set-equality",
            .total_partition => "total-partition",
            .exactly_one => "exactly-one",
            .at_least_one => "at-least-one",
            .all_rules => "all",
            .any_rules => "any",
            .no_rules => "none",
            .keyed_unique => "keyed-unique",
            .keyed_join => "keyed-join",
            .reference_exists => "reference-exists",
            .field_equal => "field-equal",
            .field_not_equal => "field-not-equal",
            .cross_input_equal => "cross-input-equal",
            .predecessor_successor => "predecessor-successor",
            .total_mapping => "total-mapping",
            .canonical_json => "canonical-json",
            .canonical_text => "canonical-text",
            .content_address => "content-address",
            .composite_identity => "composite-identity",
            .timestamp_ordinal => "timestamp-ordinal",
            .path_format => "path-format",
            .set_order => "set-order",
            .immutable_document => "immutable-document",
            .append_only_log => "append-only-log",
            .event_envelope => "event-envelope",
            .previous_digest => "previous-digest",
            .body_digest => "body-digest",
            .event_digest => "event-digest",
            .event_kinds => "event-kinds",
            .transition_table => "transition-table",
            .idempotency_key => "idempotency-key",
            .compare_append => "compare-and-append",
            .compare_replace => "compare-and-replace",
            .create_new => "create-new",
            .exclusive_custody => "exclusive-custody",
            .atomic_transaction => "atomic-transaction",
            .id_lookup => "id-lookup",
            .text_render => "text-render",
            else => @tagName(self),
        };
    }

    pub fn parse(text: []const u8) !Operator {
        inline for (@typeInfo(Operator).@"enum".fields) |field| {
            const value: Operator = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, value.id())) return value;
        }
        return error.UnsupportedArtifactOperator;
    }

    pub fn version(_: Operator) u16 {
        return 1;
    }
};

pub const Codec = enum {
    json,
    jsonl,
    text,

    fn parse(text: []const u8) !Codec {
        inline for (@typeInfo(Codec).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return error.UnsupportedCodec;
    }
};

pub const StorageKind = enum {
    pure,
    addressed_document,
    event_log,

    fn parse(text: []const u8) !StorageKind {
        if (std.mem.eql(u8, text, "pure")) return .pure;
        if (std.mem.eql(u8, text, "addressed-document")) return .addressed_document;
        if (std.mem.eql(u8, text, "event-log")) return .event_log;
        return error.UnsupportedStorageKind;
    }
};

pub const Input = struct {
    name: []u8,
    codec: Codec,
    required: bool,
    max_bytes: usize,

    pub fn deinit(self: *Input, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Rule = struct {
    operator: Operator,
    pointer_id: ?u16,
    canonical_config: []u8,

    fn deinit(self: *Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_config);
        self.* = undefined;
    }
};

pub const NamedPlan = struct {
    name: []u8,
    rule_start: usize,
    rule_count: usize,
    canonical_config: []u8,

    fn deinit(self: *NamedPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.canonical_config);
        self.* = undefined;
    }
};

pub const Bounds = struct {
    max_input_bytes: usize,
    max_store_bytes: usize,
    max_records: usize,
    max_output_bytes: usize,
    max_diagnostics: usize,
    max_reducer_states: usize,
};

pub const Plan = struct {
    id: []u8,
    owner: []u8,
    closure_digest: [71]u8,
    operator_mask: u128,
    parameter_declarations: definition_core.parameters.Declarations,
    inputs: []Input,
    storage_kind: StorageKind,
    pointers: [][]u8,
    rules: []Rule,
    operations: []NamedPlan,
    projections: []NamedPlan,
    bounds: Bounds,
    canonicalization_json: []u8,
    identity_json: []u8,
    storage_json: []u8,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.owner);
        self.parameter_declarations.deinit(allocator);
        for (self.inputs) |*input| input.deinit(allocator);
        allocator.free(self.inputs);
        for (self.pointers) |pointer| allocator.free(pointer);
        allocator.free(self.pointers);
        for (self.rules) |*rule| rule.deinit(allocator);
        allocator.free(self.rules);
        for (self.operations) |*operation| operation.deinit(allocator);
        allocator.free(self.operations);
        for (self.projections) |*projection| projection.deinit(allocator);
        allocator.free(self.projections);
        allocator.free(self.canonicalization_json);
        allocator.free(self.identity_json);
        allocator.free(self.storage_json);
        self.* = undefined;
    }

    pub fn requires(self: Plan, operator: Operator) bool {
        return (self.operator_mask & operatorBit(operator)) != 0;
    }
};

const Compiler = struct {
    allocator: std.mem.Allocator,
    operator_mask: u128,
    pointers: std.ArrayList([]u8) = .empty,
    rules: std.ArrayList(Rule) = .empty,

    fn deinit(self: *Compiler) void {
        for (self.pointers.items) |pointer| self.allocator.free(pointer);
        self.pointers.deinit(self.allocator);
        for (self.rules.items) |*rule| rule.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        self.* = undefined;
    }

    fn compileValue(self: *Compiler, value: std.json.Value, depth: usize) !void {
        if (depth > 64) return error.ArtifactRuleDepthExceeded;
        switch (value) {
            .object => |object| {
                try rejectExecutableKeys(object);
                if (object.get("op")) |raw_operator| {
                    const operator = try Operator.parse(
                        try definition_core.json.string(raw_operator),
                    );
                    if ((self.operator_mask & operatorBit(operator)) == 0) {
                        return error.UndeclaredArtifactOperator;
                    }
                    const pointer_id = if (object.get("path")) |raw_path|
                        try self.internPointer(try definition_core.json.string(raw_path))
                    else
                        null;
                    const canonical = try definition_core.canonical_json.canonicalJsonAlloc(
                        self.allocator,
                        value,
                    );
                    errdefer self.allocator.free(canonical);
                    try self.rules.append(self.allocator, .{
                        .operator = operator,
                        .pointer_id = pointer_id,
                        .canonical_config = canonical,
                    });
                    return;
                }
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    try self.compileValue(entry.value_ptr.*, depth + 1);
                }
            },
            .array => |items| for (items.items) |item| {
                try self.compileValue(item, depth + 1);
            },
            else => {},
        }
    }

    fn internPointer(self: *Compiler, pointer: []const u8) !u16 {
        try validateJsonPointer(pointer);
        for (self.pointers.items, 0..) |prior, index| {
            if (std.mem.eql(u8, prior, pointer)) return @intCast(index);
        }
        if (self.pointers.items.len == 65_535) return error.TooManyJsonPointers;
        try self.pointers.append(
            self.allocator,
            try self.allocator.dupe(u8, pointer),
        );
        return @intCast(self.pointers.items.len - 1);
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
    try rejectExecutableFields(parsed.value, 0);
    try definition_core.json.requireExactKeys(root, &.{
        "schema",
        "id",
        "owner",
        "imports",
        "requires",
        "parameters",
        "inputs",
        "canonicalization",
        "shape",
        "constraints",
        "identity",
        "storage",
        "operations",
        "projections",
        "diagnostics",
        "bounds",
    });
    try definition_core.json.requireFields(root, &.{
        "schema",
        "id",
        "owner",
        "requires",
        "inputs",
        "canonicalization",
        "shape",
        "constraints",
        "identity",
        "storage",
        "operations",
        "projections",
        "bounds",
    });
    if (!std.mem.eql(
        u8,
        try definition_core.json.requiredString(root, "schema"),
        schema,
    )) return error.InvalidArtifactDefinitionSchema;
    const id = try definition_core.json.requiredString(root, "id");
    const owner = try definition_core.json.requiredString(root, "owner");
    try definition_core.json.safeIdentifier(id, 256);
    try definition_core.json.safeIdentifier(owner, 128);

    const operator_mask = try parseRequires(try definition_core.json.object(
        try definition_core.json.field(root, "requires"),
    ));
    var parameter_declarations = try definition_core.parameters.compile(
        allocator,
        root.get("parameters"),
    );
    errdefer parameter_declarations.deinit(allocator);
    const inputs = try parseInputs(
        allocator,
        try definition_core.json.object(try definition_core.json.field(root, "inputs")),
    );
    errdefer deinitInputs(allocator, inputs);
    const storage_object = try definition_core.json.object(
        try definition_core.json.field(root, "storage"),
    );
    try rejectExecutableKeys(storage_object);
    const storage_kind = StorageKind.parse(
        try definition_core.json.requiredString(storage_object, "kind"),
    ) catch return error.UnsupportedStorageKind;
    const bounds = try parseBounds(try definition_core.json.object(
        try definition_core.json.field(root, "bounds"),
    ));

    var compiler = Compiler{
        .allocator = allocator,
        .operator_mask = operator_mask,
    };
    errdefer compiler.deinit();
    try compiler.compileValue(try definition_core.json.field(root, "canonicalization"), 0);
    try compiler.compileValue(try definition_core.json.field(root, "shape"), 0);
    try compiler.compileValue(try definition_core.json.field(root, "constraints"), 0);
    try compiler.compileValue(try definition_core.json.field(root, "identity"), 0);
    try compiler.compileValue(try definition_core.json.field(root, "storage"), 0);

    const operations = try parseNamedPlans(
        allocator,
        &compiler,
        try definition_core.json.object(try definition_core.json.field(root, "operations")),
    );
    errdefer deinitNamedPlans(allocator, operations);
    const projections = try parseNamedPlans(
        allocator,
        &compiler,
        try definition_core.json.object(try definition_core.json.field(root, "projections")),
    );
    errdefer deinitNamedPlans(allocator, projections);
    if (root.get("diagnostics")) |diagnostics| try compiler.compileValue(diagnostics, 0);

    const canonicalization_json = try definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        try definition_core.json.field(root, "canonicalization"),
    );
    errdefer allocator.free(canonicalization_json);
    const identity_json = try definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        try definition_core.json.field(root, "identity"),
    );
    errdefer allocator.free(identity_json);
    const storage_json = try definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        try definition_core.json.field(root, "storage"),
    );
    errdefer allocator.free(storage_json);

    const pointers = try compiler.pointers.toOwnedSlice(allocator);
    errdefer deinitPointers(allocator, pointers);
    const rules = try compiler.rules.toOwnedSlice(allocator);
    errdefer deinitRules(allocator, rules);
    return .{
        .id = try allocator.dupe(u8, id),
        .owner = try allocator.dupe(u8, owner),
        .closure_digest = closure.digest,
        .operator_mask = operator_mask,
        .parameter_declarations = parameter_declarations,
        .inputs = inputs,
        .storage_kind = storage_kind,
        .pointers = pointers,
        .rules = rules,
        .operations = operations,
        .projections = projections,
        .bounds = bounds,
        .canonicalization_json = canonicalization_json,
        .identity_json = identity_json,
        .storage_json = storage_json,
    };
}

fn parseRequires(object: std.json.ObjectMap) !u128 {
    try definition_core.json.requireExactKeys(object, &.{ "abi", "operators" });
    try definition_core.json.requireFields(object, &.{ "abi", "operators" });
    if (!std.mem.eql(
        u8,
        try definition_core.json.requiredString(object, "abi"),
        abi,
    )) return error.IncompatibleArtifactAbi;
    const items = try definition_core.json.array(
        try definition_core.json.field(object, "operators"),
    );
    var mask: u128 = 0;
    for (items.items) |item| {
        const operator = try Operator.parse(try definition_core.json.string(item));
        const bit = operatorBit(operator);
        if ((mask & bit) != 0) return error.DuplicateArtifactOperator;
        mask |= bit;
    }
    return mask;
}

fn parseInputs(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) ![]Input {
    if (object.count() == 0 or object.count() > 64) return error.InvalidInputCount;
    var out: std.ArrayList(Input) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try definition_core.json.safeIdentifier(entry.key_ptr.*, 128);
        const declaration = try definition_core.json.object(entry.value_ptr.*);
        try definition_core.json.requireExactKeys(declaration, &.{
            "codec", "required", "max_bytes",
        });
        try definition_core.json.requireFields(declaration, &.{ "codec", "max_bytes" });
        const max_bytes = try definition_core.json.unsigned(
            try definition_core.json.field(declaration, "max_bytes"),
        );
        if (max_bytes == 0 or max_bytes > 256 * 1024 * 1024) {
            return error.InputBoundsExceeded;
        }
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .codec = try Codec.parse(try definition_core.json.requiredString(declaration, "codec")),
            .required = if (declaration.get("required")) |raw|
                try definition_core.json.boolean(raw)
            else
                true,
            .max_bytes = max_bytes,
        });
    }
    std.mem.sort(Input, out.items, {}, struct {
        fn lessThan(_: void, left: Input, right: Input) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return out.toOwnedSlice(allocator);
}

fn parseNamedPlans(
    allocator: std.mem.Allocator,
    compiler: *Compiler,
    object: std.json.ObjectMap,
) ![]NamedPlan {
    if (object.count() > 128) return error.TooManyNamedPlans;
    var out: std.ArrayList(NamedPlan) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try definition_core.json.safeIdentifier(entry.key_ptr.*, 128);
        const start = compiler.rules.items.len;
        try compiler.compileValue(entry.value_ptr.*, 0);
        const canonical = try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            entry.value_ptr.*,
        );
        errdefer allocator.free(canonical);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .rule_start = start,
            .rule_count = compiler.rules.items.len - start,
            .canonical_config = canonical,
        });
    }
    std.mem.sort(NamedPlan, out.items, {}, struct {
        fn lessThan(_: void, left: NamedPlan, right: NamedPlan) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return out.toOwnedSlice(allocator);
}

fn parseBounds(object: std.json.ObjectMap) !Bounds {
    try definition_core.json.requireExactKeys(object, &.{
        "max_input_bytes",
        "max_store_bytes",
        "max_records",
        "max_output_bytes",
        "max_diagnostics",
        "max_reducer_states",
    });
    try definition_core.json.requireFields(object, &.{
        "max_input_bytes",
        "max_store_bytes",
        "max_records",
        "max_output_bytes",
        "max_diagnostics",
        "max_reducer_states",
    });
    const bounds: Bounds = .{
        .max_input_bytes = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_input_bytes"),
        ),
        .max_store_bytes = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_store_bytes"),
        ),
        .max_records = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_records"),
        ),
        .max_output_bytes = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_output_bytes"),
        ),
        .max_diagnostics = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_diagnostics"),
        ),
        .max_reducer_states = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_reducer_states"),
        ),
    };
    if (bounds.max_input_bytes == 0 or bounds.max_input_bytes > 256 * 1024 * 1024 or
        bounds.max_store_bytes == 0 or bounds.max_store_bytes > 4 * 1024 * 1024 * 1024 or
        bounds.max_records == 0 or bounds.max_records > 10_000_000 or
        bounds.max_output_bytes == 0 or bounds.max_output_bytes > 256 * 1024 * 1024 or
        bounds.max_diagnostics == 0 or bounds.max_diagnostics > 1024 or
        bounds.max_reducer_states == 0 or bounds.max_reducer_states > 65_536)
    {
        return error.ArtifactBoundsExceeded;
    }
    return bounds;
}

fn rejectExecutableKeys(object: std.json.ObjectMap) !void {
    const forbidden = [_][]const u8{
        "hook",
        "execute",
        "executor_hook",
        "executable",
        "executable_hook",
        "process_hook",
        "interpreter",
        "script",
        "shell",
        "python",
        "javascript",
        "wasm",
        "wasm_component",
        "plugin",
        "dynamic_library",
        "network_access",
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        for (forbidden) |name| if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
            return error.ExecutableDefinitionField;
        };
    }
}

fn rejectExecutableFields(value: std.json.Value, depth: usize) !void {
    if (depth > 64) return error.ArtifactRuleDepthExceeded;
    switch (value) {
        .object => |object| {
            try rejectExecutableKeys(object);
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try rejectExecutableFields(entry.value_ptr.*, depth + 1);
            }
        },
        .array => |items| for (items.items) |item| {
            try rejectExecutableFields(item, depth + 1);
        },
        else => {},
    }
}

fn validateJsonPointer(pointer: []const u8) !void {
    if (pointer.len > 1024 or !std.unicode.utf8ValidateSlice(pointer)) {
        return error.InvalidJsonPointer;
    }
    if (pointer.len == 0) return;
    if (pointer[0] != '/') return error.InvalidJsonPointer;
    var index: usize = 0;
    while (index < pointer.len) : (index += 1) {
        const byte = pointer[index];
        if (byte < 0x20 or byte == 0x7f) return error.InvalidJsonPointer;
        if (byte != '~') continue;
        if (index + 1 >= pointer.len or
            (pointer[index + 1] != '0' and pointer[index + 1] != '1'))
        {
            return error.InvalidJsonPointer;
        }
        index += 1;
    }
}

fn operatorBit(operator: Operator) u128 {
    return @as(u128, 1) << @intCast(@intFromEnum(operator));
}

fn deinitInputs(allocator: std.mem.Allocator, inputs: []Input) void {
    for (inputs) |*input| input.deinit(allocator);
    allocator.free(inputs);
}

fn deinitPointers(allocator: std.mem.Allocator, pointers: [][]u8) void {
    for (pointers) |pointer| allocator.free(pointer);
    allocator.free(pointers);
}

fn deinitRules(allocator: std.mem.Allocator, rules: []Rule) void {
    for (rules) |*rule| rule.deinit(allocator);
    allocator.free(rules);
}

fn deinitNamedPlans(allocator: std.mem.Allocator, plans: []NamedPlan) void {
    for (plans) |*plan| plan.deinit(allocator);
    allocator.free(plans);
}

test "artifact definition compiles structural rules and effect plans" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{
        \\  "schema":"ledger-artifact-definition/v1",
        \\  "id":"example/record",
        \\  "owner":"example",
        \\  "requires":{"abi":"ledger-artifact-abi/v1","operators":["canonical-json","exact-object","scalar-type","enum","content-address","immutable-document","create-new","select"]},
        \\  "inputs":{"record":{"codec":"json","max_bytes":1048576}},
        \\  "canonicalization":{"steps":[{"op":"canonical-json","input":"record"}]},
        \\  "shape":{"rules":[{"op":"exact-object","path":"","keys":["schema","record_id","value"]},{"op":"scalar-type","path":"/schema","type":"string"},{"op":"enum","path":"/schema","values":["example-record/v1"]}]},
        \\  "constraints":[],
        \\  "identity":{"op":"content-address","input":"record","exclude":"/record_id"},
        \\  "storage":{"kind":"addressed-document","slots":[{"op":"immutable-document","name":"records"}]},
        \\  "operations":{"create":{"effects":[{"op":"create-new","slot":"records"}]}},
        \\  "projections":{"show":{"pipeline":[{"op":"select","fields":["record_id","value"]}]}},
        \\  "diagnostics":{},
        \\  "bounds":{"max_input_bytes":1048576,"max_store_bytes":16777216,"max_records":10000,"max_output_bytes":1048576,"max_diagnostics":64,"max_reducer_states":256}
        \\}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var plan = try compile(std.testing.allocator, &closure, "artifact.json");
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("example/record", plan.id);
    try std.testing.expectEqual(.addressed_document, plan.storage_kind);
    try std.testing.expect(plan.requires(.content_address));
    try std.testing.expectEqual(@as(usize, 2), plan.pointers.len);
    try std.testing.expectEqual(@as(usize, 1), plan.operations.len);
    try std.testing.expectEqual(@as(usize, 1), plan.projections.len);
}

test "artifact definition rejects executable hooks and undeclared operators" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "hook.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/hook","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":[]},"inputs":{"record":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{"hook":"run"},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":1024,"max_records":1,"max_output_bytes":1024,"max_diagnostics":1,"max_reducer_states":1}}
        ,
    });
    var hook_closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "hook.json",
        .{},
    );
    defer hook_closure.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ExecutableDefinitionField,
        compile(std.testing.allocator, &hook_closure, "hook.json"),
    );

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "nested-hook.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/nested-hook","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object"]},"inputs":{"record":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","path":"","keys":[],"extension":{"hook":"run"}}]},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":1024,"max_records":1,"max_output_bytes":1024,"max_diagnostics":1,"max_reducer_states":1}}
        ,
    });
    var nested_hook_closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "nested-hook.json",
        .{},
    );
    defer nested_hook_closure.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ExecutableDefinitionField,
        compile(std.testing.allocator, &nested_hook_closure, "nested-hook.json"),
    );

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "operator.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/operator","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":[]},"inputs":{"record":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{"rules":[{"op":"scalar-type","path":"/value","type":"string"}]},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":1024,"max_records":1,"max_output_bytes":1024,"max_diagnostics":1,"max_reducer_states":1}}
        ,
    });
    var operator_closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "operator.json",
        .{},
    );
    defer operator_closure.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UndeclaredArtifactOperator,
        compile(std.testing.allocator, &operator_closure, "operator.json"),
    );
}

test "artifact definition permits inert command data fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "inert.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/inert-command","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object"]},"inputs":{"record":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","path":"","keys":["argv","command"]}]},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":1024,"max_records":1,"max_output_bytes":1024,"max_diagnostics":1,"max_reducer_states":1}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "inert.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var plan = try compile(std.testing.allocator, &closure, "inert.json");
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), plan.rules.len);
}
