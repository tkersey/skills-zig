const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");

pub const InputDocument = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const InputDigest = struct {
    name: []u8,
    digest: []u8,

    fn deinit(self: *InputDigest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.digest);
        self.* = undefined;
    }
};

pub const Result = struct {
    definition_id: []u8,
    definition_digest: [71]u8,
    input_digests: []InputDigest,
    diagnostics: definition_core.diagnostics.Collector,
    valid: bool,
    authority_granted: bool = false,
    storage_mutated: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.definition_id);
        for (self.input_digests) |*digest| digest.deinit(allocator);
        allocator.free(self.input_digests);
        self.diagnostics.deinit();
        self.* = undefined;
    }
};

const Pointer = definition_core.json_pointer.Pointer;

const JsonKind = enum {
    string,
    integer,
    number,
    boolean,
    array,
    object,
    null,

    fn parse(text: []const u8) !JsonKind {
        inline for (@typeInfo(JsonKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return error.UnsupportedJsonKind;
    }
};

const EnumScalar = union(enum) {
    string: []u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null,

    fn deinit(self: *EnumScalar, allocator: std.mem.Allocator) void {
        if (self.* == .string) allocator.free(self.string);
        self.* = undefined;
    }
};

const CompiledRule = struct {
    operator: definition.Operator,
    input_index: u8,
    pointer_id: ?u16,
    other_input_index: ?u8 = null,
    other_pointer_id: ?u16 = null,
    path_ids: []u16,
    keys: [][]u8,
    values: []EnumScalar,
    scalar_kind: ?JsonKind = null,
    min_count: ?usize = null,
    max_count: ?usize = null,
    min_number: ?f64 = null,
    max_number: ?f64 = null,
    children: []CompiledRule,

    fn deinit(self: *CompiledRule, allocator: std.mem.Allocator) void {
        allocator.free(self.path_ids);
        for (self.keys) |key| allocator.free(key);
        allocator.free(self.keys);
        for (self.values) |*value| value.deinit(allocator);
        allocator.free(self.values);
        for (self.children) |*child| child.deinit(allocator);
        allocator.free(self.children);
        self.* = undefined;
    }
};

pub const Plan = struct {
    inputs: []definition.Input,
    pointers: []Pointer,
    rules: []CompiledRule,
    max_input_bytes: usize,
    max_records: usize,
    max_diagnostics: usize,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.inputs) |*input| input.deinit(allocator);
        allocator.free(self.inputs);
        for (self.pointers) |*pointer| pointer.deinit(allocator);
        allocator.free(self.pointers);
        for (self.rules) |*rule| rule.deinit(allocator);
        allocator.free(self.rules);
        self.* = undefined;
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    pointers: std.ArrayList(Pointer) = .empty,
    rules: std.ArrayList(CompiledRule) = .empty,
    item_rule_count: usize = 0,

    fn deinit(self: *Builder) void {
        for (self.pointers.items) |*pointer| pointer.deinit(self.allocator);
        self.pointers.deinit(self.allocator);
        for (self.rules.items) |*rule| rule.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        self.* = undefined;
    }

    fn internPointer(self: *Builder, raw: []const u8) !u16 {
        for (self.pointers.items, 0..) |pointer, index| {
            if (std.mem.eql(u8, pointer.raw, raw)) return @intCast(index);
        }
        if (self.pointers.items.len == 65_535) return error.TooManyJsonPointers;
        var pointer = try definition_core.json_pointer.compile(
            self.allocator,
            raw,
        );
        errdefer pointer.deinit(self.allocator);
        try self.pointers.append(self.allocator, pointer);
        return @intCast(self.pointers.items.len - 1);
    }

    fn inputIndex(self: Builder, name: []const u8) !u8 {
        for (self.definition_plan.inputs, 0..) |input, index| {
            if (std.mem.eql(u8, input.name, name)) return @intCast(index);
        }
        return error.UnknownRuleInput;
    }

    fn compileRule(self: *Builder, source: definition.Rule) !void {
        if (!isValidationOperator(source.operator)) return;
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            source.canonical_config,
            .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
            },
        );
        defer parsed.deinit();
        const object = try definition_core.json.object(parsed.value);
        const input_index = if (object.get("input")) |raw_input|
            try self.inputIndex(try definition_core.json.string(raw_input))
        else if (self.definition_plan.inputs.len == 1)
            0
        else
            return error.AmbiguousRuleInput;

        var rule: CompiledRule = .{
            .operator = source.operator,
            .input_index = input_index,
            .pointer_id = source.pointer_id,
            .path_ids = try self.allocator.alloc(u16, 0),
            .keys = try self.allocator.alloc([]u8, 0),
            .values = try self.allocator.alloc(EnumScalar, 0),
            .children = try self.allocator.alloc(CompiledRule, 0),
        };
        errdefer rule.deinit(self.allocator);

        switch (source.operator) {
            .exact_object => rule.keys = try parseStringSet(
                self.allocator,
                try definition_core.json.field(object, "keys"),
            ),
            .scalar_type => rule.scalar_kind = try JsonKind.parse(
                try definition_core.json.requiredString(object, "type"),
            ),
            .bounded_string,
            .bounded_array,
            .bounded_object,
            .safe_identifier,
            => {
                rule.min_count = try optionalUnsigned(object, "min");
                rule.max_count = try optionalUnsigned(object, "max");
                if (rule.min_count == null and rule.max_count == null and
                    source.operator != .safe_identifier)
                {
                    return error.MissingRuleBound;
                }
                if (rule.min_count != null and rule.max_count != null and
                    rule.min_count.? > rule.max_count.?)
                {
                    return error.InvalidRuleBounds;
                }
            },
            .bounded_number => {
                rule.min_number = try optionalNumber(object, "min");
                rule.max_number = try optionalNumber(object, "max");
                if (rule.min_number == null and rule.max_number == null) {
                    return error.MissingRuleBound;
                }
                if (rule.min_number != null and rule.max_number != null and
                    rule.min_number.? > rule.max_number.?)
                {
                    return error.InvalidRuleBounds;
                }
            },
            .enum_value => rule.values = try parseEnumValues(
                self.allocator,
                try definition_core.json.field(object, "values"),
            ),
            .set_equality,
            .subset,
            .superset,
            .disjoint,
            .field_equal,
            .field_not_equal,
            => {
                const scope_pointer_id = source.pointer_id;
                const left_input = if (object.get("left_input")) |raw|
                    try self.inputIndex(try definition_core.json.string(raw))
                else
                    input_index;
                const right_input = if (object.get("right_input")) |raw|
                    try self.inputIndex(try definition_core.json.string(raw))
                else
                    input_index;
                rule.input_index = left_input;
                rule.other_input_index = right_input;
                rule.pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "left"),
                );
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "right"),
                );
                if (scope_pointer_id) |scope| {
                    if (left_input != right_input) {
                        return error.ScopedComparisonInputsConflict;
                    }
                    rule.path_ids = try self.allocator.alloc(u16, 1);
                    rule.path_ids[0] = scope;
                }
            },
            .cross_input_equal => {
                rule.input_index = try self.inputIndex(
                    try definition_core.json.requiredString(object, "left_input"),
                );
                rule.other_input_index = try self.inputIndex(
                    try definition_core.json.requiredString(object, "right_input"),
                );
                rule.pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "left"),
                );
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "right"),
                );
            },
            .implies => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "if", "equals", "then" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "if", "then" },
                );
                rule.pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "if"),
                );
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "then"),
                );
                if (object.get("equals")) |value| {
                    var expected = try parseEnumScalar(
                        self.allocator,
                        value,
                    );
                    errdefer expected.deinit(self.allocator);
                    const values = try self.allocator.alloc(EnumScalar, 1);
                    values[0] = expected;
                    rule.values = values;
                }
            },
            .total_partition => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "universe", "parts" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "universe", "parts" },
                );
                rule.pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(
                        object,
                        "universe",
                    ),
                );
                rule.path_ids = try self.parsePaths(
                    try definition_core.json.field(object, "parts"),
                );
                if (rule.path_ids.len < 2) {
                    return error.TotalPartitionRequiresMultipleParts;
                }
            },
            .total_mapping => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{
                        "op",
                        "input",
                        "source",
                        "target",
                        "mapping",
                        "from",
                        "to",
                    },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{
                        "op",
                        "source",
                        "target",
                        "mapping",
                        "from",
                        "to",
                    },
                );
                rule.pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(
                        object,
                        "source",
                    ),
                );
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(
                        object,
                        "target",
                    ),
                );
                rule.path_ids = try self.allocator.alloc(u16, 3);
                rule.path_ids[0] = try self.internPointer(
                    try definition_core.json.requiredString(
                        object,
                        "mapping",
                    ),
                );
                rule.path_ids[1] = try self.internPointer(
                    try definition_core.json.requiredString(object, "from"),
                );
                rule.path_ids[2] = try self.internPointer(
                    try definition_core.json.requiredString(object, "to"),
                );
            },
            .exactly_one, .at_least_one => rule.path_ids = try self.parsePaths(
                try definition_core.json.field(object, "paths"),
            ),
            .all_rules, .any_rules, .no_rules => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "path", "rules" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "path", "rules" },
                );
                rule.children = try self.compileItemRules(
                    try definition_core.json.field(object, "rules"),
                    input_index,
                    0,
                );
            },
            .keyed_unique => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "path", "key" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "path", "key" },
                );
                if (source.pointer_id == null) {
                    return error.KeyedUniqueCollectionMissing;
                }
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "key"),
                );
            },
            .reference_exists => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{
                        "op",
                        "input",
                        "path",
                        "reference",
                        "target_input",
                        "target",
                        "key",
                    },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "path", "reference", "target", "key" },
                );
                if (source.pointer_id == null) {
                    return error.ReferenceCollectionMissing;
                }
                rule.other_input_index = if (object.get("target_input")) |raw|
                    try self.inputIndex(try definition_core.json.string(raw))
                else
                    input_index;
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(
                        object,
                        "reference",
                    ),
                );
                rule.path_ids = try self.allocator.alloc(u16, 2);
                rule.path_ids[0] = try self.internPointer(
                    try definition_core.json.requiredString(object, "target"),
                );
                rule.path_ids[1] = try self.internPointer(
                    try definition_core.json.requiredString(object, "key"),
                );
            },
            else => {},
        }
        try self.rules.append(self.allocator, rule);
    }

    fn compileItemRules(
        self: *Builder,
        raw: std.json.Value,
        input_index: u8,
        depth: usize,
    ) anyerror![]CompiledRule {
        if (depth > 16) return error.ItemRuleDepthExceeded;
        const items = try definition_core.json.array(raw);
        if (items.items.len == 0 or items.items.len > 64) {
            return error.ItemRuleCountInvalid;
        }
        self.item_rule_count = std.math.add(
            usize,
            self.item_rule_count,
            items.items.len,
        ) catch return error.TooManyItemRules;
        if (self.item_rule_count > 65_535) return error.TooManyItemRules;
        const rules = try self.allocator.alloc(CompiledRule, items.items.len);
        var initialized: usize = 0;
        errdefer {
            for (rules[0..initialized]) |*rule| rule.deinit(self.allocator);
            self.allocator.free(rules);
        }
        for (items.items, 0..) |item, index| {
            rules[index] = try self.compileItemRule(
                try definition_core.json.object(item),
                input_index,
                depth,
            );
            initialized += 1;
        }
        return rules;
    }

    fn compileItemRule(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        depth: usize,
    ) anyerror!CompiledRule {
        const operator = try definition.Operator.parse(
            try definition_core.json.requiredString(object, "op"),
        );
        if (!self.definition_plan.requires(operator)) {
            return error.UndeclaredArtifactOperator;
        }
        if (!isItemOperator(operator)) return error.UnsupportedItemOperator;
        if (object.contains("input")) return error.ItemRuleInputForbidden;
        const pointer_id = if (object.get("path")) |raw|
            try self.internPointer(try definition_core.json.string(raw))
        else
            null;
        var rule: CompiledRule = .{
            .operator = operator,
            .input_index = input_index,
            .pointer_id = pointer_id,
            .path_ids = try self.allocator.alloc(u16, 0),
            .keys = try self.allocator.alloc([]u8, 0),
            .values = try self.allocator.alloc(EnumScalar, 0),
            .children = try self.allocator.alloc(CompiledRule, 0),
        };
        errdefer rule.deinit(self.allocator);
        switch (operator) {
            .exact_object => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "keys" },
                );
                rule.keys = try parseStringSet(
                    self.allocator,
                    try definition_core.json.field(object, "keys"),
                );
            },
            .required_field,
            .optional_field,
            .digest,
            .timestamp,
            .safe_relative_path,
            .unique,
            .sorted,
            => try definition_core.json.requireExactKeys(
                object,
                &.{ "op", "path" },
            ),
            .scalar_type => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "type" },
                );
                rule.scalar_kind = try JsonKind.parse(
                    try definition_core.json.requiredString(object, "type"),
                );
            },
            .bounded_string,
            .bounded_array,
            .bounded_object,
            .safe_identifier,
            => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "min", "max" },
                );
                rule.min_count = try optionalUnsigned(object, "min");
                rule.max_count = try optionalUnsigned(object, "max");
                if (rule.min_count == null and rule.max_count == null and
                    operator != .safe_identifier)
                {
                    return error.MissingRuleBound;
                }
                if (rule.min_count != null and rule.max_count != null and
                    rule.min_count.? > rule.max_count.?)
                {
                    return error.InvalidRuleBounds;
                }
            },
            .bounded_number => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "min", "max" },
                );
                rule.min_number = try optionalNumber(object, "min");
                rule.max_number = try optionalNumber(object, "max");
                if (rule.min_number == null and rule.max_number == null) {
                    return error.MissingRuleBound;
                }
                if (rule.min_number != null and rule.max_number != null and
                    rule.min_number.? > rule.max_number.?)
                {
                    return error.InvalidRuleBounds;
                }
            },
            .enum_value => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "values" },
                );
                rule.values = try parseEnumValues(
                    self.allocator,
                    try definition_core.json.field(object, "values"),
                );
            },
            .set_equality,
            .subset,
            .superset,
            .disjoint,
            .field_equal,
            .field_not_equal,
            => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "left", "right" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "left", "right" },
                );
                rule.pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "left"),
                );
                rule.other_input_index = input_index;
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "right"),
                );
            },
            .exactly_one, .at_least_one => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "paths" },
                );
                rule.path_ids = try self.parsePaths(
                    try definition_core.json.field(object, "paths"),
                );
            },
            .keyed_unique => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "key" },
                );
                if (pointer_id == null) {
                    return error.KeyedUniqueCollectionMissing;
                }
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "key"),
                );
            },
            .implies => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "if", "equals", "then" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "if", "then" },
                );
                rule.pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "if"),
                );
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "then"),
                );
                if (object.get("equals")) |value| {
                    const values = try self.allocator.alloc(EnumScalar, 1);
                    errdefer self.allocator.free(values);
                    values[0] = try parseEnumScalar(self.allocator, value);
                    rule.values = values;
                }
            },
            .all_rules, .any_rules, .no_rules => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "rules" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "path", "rules" },
                );
                rule.children = try self.compileItemRules(
                    try definition_core.json.field(object, "rules"),
                    input_index,
                    depth + 1,
                );
            },
            else => unreachable,
        }
        return rule;
    }

    fn parsePaths(self: *Builder, raw: std.json.Value) ![]u16 {
        const items = try definition_core.json.array(raw);
        if (items.items.len == 0 or items.items.len > 1024) {
            return error.InvalidRulePathCount;
        }
        const out = try self.allocator.alloc(u16, items.items.len);
        errdefer self.allocator.free(out);
        for (items.items, 0..) |item, index| {
            out[index] = try self.internPointer(try definition_core.json.string(item));
        }
        return out;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
) !Plan {
    var builder = Builder{
        .allocator = allocator,
        .definition_plan = definition_plan,
    };
    errdefer builder.deinit();
    for (definition_plan.pointers) |pointer| _ = try builder.internPointer(pointer);
    for (definition_plan.rules) |rule| try builder.compileRule(rule);
    const inputs = try cloneInputs(allocator, definition_plan.inputs);
    errdefer {
        for (inputs) |*input| input.deinit(allocator);
        allocator.free(inputs);
    }
    const pointers = try builder.pointers.toOwnedSlice(allocator);
    errdefer {
        for (pointers) |*pointer| pointer.deinit(allocator);
        allocator.free(pointers);
    }
    const rules = try builder.rules.toOwnedSlice(allocator);
    return .{
        .inputs = inputs,
        .pointers = pointers,
        .rules = rules,
        .max_input_bytes = definition_plan.bounds.max_input_bytes,
        .max_records = definition_plan.bounds.max_records,
        .max_diagnostics = definition_plan.bounds.max_diagnostics,
    };
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(3);
    try encoder.writeCount(plan.inputs.len);
    for (plan.inputs) |input| {
        try encoder.writeBytes(input.name);
        try encoder.writeEnum(input.codec);
        try encoder.writeBool(input.required);
        try encoder.writeUsize(input.max_bytes);
    }
    try encoder.writeCount(plan.pointers.len);
    for (plan.pointers) |pointer| try encoder.writeBytes(pointer.raw);
    try encoder.writeCount(plan.rules.len);
    for (plan.rules) |rule| try encodeCompiledRule(encoder, rule);
    try encoder.writeUsize(plan.max_input_bytes);
    try encoder.writeUsize(plan.max_records);
    try encoder.writeUsize(plan.max_diagnostics);
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 3) {
        return error.LedgerValidationCacheVersionMismatch;
    }
    const inputs = try decodeCacheInputs(allocator, decoder);
    errdefer {
        for (inputs) |*input| input.deinit(allocator);
        allocator.free(inputs);
    }
    const pointers = try decodeCachePointers(allocator, decoder);
    errdefer {
        for (pointers) |*pointer| pointer.deinit(allocator);
        allocator.free(pointers);
    }
    var total_rule_count: usize = 0;
    const rules = try decodeCacheRules(
        allocator,
        decoder,
        inputs.len,
        pointers.len,
        0,
        &total_rule_count,
    );
    errdefer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    const max_input_bytes = try decoder.readUsize();
    const max_records = try decoder.readUsize();
    const max_diagnostics = try decoder.readUsize();
    if (max_input_bytes == 0 or max_input_bytes > 256 * 1024 * 1024 or
        max_records == 0 or max_records > 10_000_000 or
        max_diagnostics == 0 or max_diagnostics > 1024)
    {
        return error.CacheValidationBoundsInvalid;
    }
    return .{
        .inputs = inputs,
        .pointers = pointers,
        .rules = rules,
        .max_input_bytes = max_input_bytes,
        .max_records = max_records,
        .max_diagnostics = max_diagnostics,
    };
}

pub fn validateCachePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
    if (plan.inputs.len != definition_plan.inputs.len or
        plan.max_input_bytes != definition_plan.bounds.max_input_bytes or
        plan.max_records != definition_plan.bounds.max_records or
        plan.max_diagnostics != definition_plan.bounds.max_diagnostics)
    {
        return error.CacheValidationPlanMismatch;
    }
    for (plan.inputs, definition_plan.inputs) |cached, declared| {
        if (!std.mem.eql(u8, cached.name, declared.name) or
            cached.codec != declared.codec or
            cached.required != declared.required or
            cached.max_bytes != declared.max_bytes)
        {
            return error.CacheValidationPlanMismatch;
        }
    }
    for (plan.rules) |rule| {
        try validateRuleAgainstDefinition(rule, definition_plan);
    }
}

fn validateRuleAgainstDefinition(
    rule: CompiledRule,
    definition_plan: *const definition.Plan,
) !void {
    if (!definition_plan.requires(rule.operator)) {
        return error.CacheValidationPlanMismatch;
    }
    for (rule.children) |child| {
        if (child.input_index != rule.input_index or
            !isItemOperator(child.operator))
        {
            return error.CacheValidationPlanMismatch;
        }
        try validateRuleAgainstDefinition(child, definition_plan);
    }
}

fn decodeCacheInputs(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]definition.Input {
    const count = try decoder.readCount(64);
    if (count == 0) return error.InvalidInputCount;
    const inputs = try allocator.alloc(definition.Input, count);
    var initialized: usize = 0;
    errdefer {
        for (inputs[0..initialized]) |*input| input.deinit(allocator);
        allocator.free(inputs);
    }
    for (inputs, 0..) |*input, index| {
        const name = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(name);
        try definition_core.json.safeIdentifier(name, 128);
        if (index != 0 and
            std.mem.order(u8, inputs[index - 1].name, name) != .lt)
        {
            return error.CacheInputsNotSorted;
        }
        const codec = try decoder.readEnum(definition.Codec);
        const required = try decoder.readBool();
        const max_bytes = try decoder.readUsize();
        if (max_bytes == 0 or max_bytes > 256 * 1024 * 1024) {
            return error.InputBoundsExceeded;
        }
        input.* = .{
            .name = name,
            .codec = codec,
            .required = required,
            .max_bytes = max_bytes,
        };
        initialized += 1;
    }
    return inputs;
}

fn decodeCachePointers(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]Pointer {
    const count = try decoder.readCount(65_535);
    const pointers = try allocator.alloc(Pointer, count);
    var initialized: usize = 0;
    errdefer {
        for (pointers[0..initialized]) |*pointer| pointer.deinit(allocator);
        allocator.free(pointers);
    }
    for (pointers) |*pointer| {
        const raw = try decoder.readBytesAlloc(allocator, 1024);
        defer allocator.free(raw);
        pointer.* = try definition_core.json_pointer.compile(allocator, raw);
        initialized += 1;
    }
    return pointers;
}

fn encodeCompiledRule(
    encoder: *definition_core.cache.Encoder,
    rule: CompiledRule,
) !void {
    try encoder.writeEnum(rule.operator);
    try encoder.writeByte(rule.input_index);
    try writeOptionalU16(encoder, rule.pointer_id);
    try writeOptionalByte(encoder, rule.other_input_index);
    try writeOptionalU16(encoder, rule.other_pointer_id);
    try encoder.writeCount(rule.path_ids.len);
    for (rule.path_ids) |path_id| try encoder.writeU16(path_id);
    try encoder.writeCount(rule.keys.len);
    for (rule.keys) |key| try encoder.writeBytes(key);
    try encoder.writeCount(rule.values.len);
    for (rule.values) |value| try encodeEnumScalar(encoder, value);
    try encoder.writeBool(rule.scalar_kind != null);
    if (rule.scalar_kind) |kind| try encoder.writeEnum(kind);
    try writeOptionalUsize(encoder, rule.min_count);
    try writeOptionalUsize(encoder, rule.max_count);
    try writeOptionalF64(encoder, rule.min_number);
    try writeOptionalF64(encoder, rule.max_number);
    try encoder.writeCount(rule.children.len);
    for (rule.children) |child| try encodeCompiledRule(encoder, child);
}

fn decodeCacheRules(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    input_count: usize,
    pointer_count: usize,
    depth: usize,
    total_rule_count: *usize,
) ![]CompiledRule {
    const count = try decoder.readCount(65_535);
    if (depth > 16 and count != 0) {
        return error.CacheItemRuleDepthExceeded;
    }
    total_rule_count.* = std.math.add(
        usize,
        total_rule_count.*,
        count,
    ) catch return error.CacheRuleCountExceeded;
    if (total_rule_count.* > 65_535) return error.CacheRuleCountExceeded;
    const rules = try allocator.alloc(CompiledRule, count);
    var initialized: usize = 0;
    errdefer {
        for (rules[0..initialized]) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    for (rules) |*destination| {
        destination.* = try decodeCacheRule(
            allocator,
            decoder,
            input_count,
            pointer_count,
            depth,
            total_rule_count,
        );
        initialized += 1;
    }
    return rules;
}

fn decodeCacheRule(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    input_count: usize,
    pointer_count: usize,
    depth: usize,
    total_rule_count: *usize,
) anyerror!CompiledRule {
    const operator = try decoder.readEnum(definition.Operator);
    const input_index = try decoder.readByte();
    const pointer_id = try readOptionalU16(decoder);
    const other_input_index = try readOptionalByte(decoder);
    const other_pointer_id = try readOptionalU16(decoder);
    const path_ids = try decodePathIds(allocator, decoder);
    errdefer allocator.free(path_ids);
    const keys = try decodeKeys(allocator, decoder);
    errdefer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }
    const values = try decodeEnumScalars(allocator, decoder);
    errdefer {
        for (values) |*value| value.deinit(allocator);
        allocator.free(values);
    }
    const scalar_kind = if (try decoder.readBool())
        try decoder.readEnum(JsonKind)
    else
        null;
    const min_count = try readOptionalUsize(decoder);
    const max_count = try readOptionalUsize(decoder);
    const min_number = try readOptionalF64(decoder);
    const max_number = try readOptionalF64(decoder);
    const children = try decodeCacheRules(
        allocator,
        decoder,
        input_count,
        pointer_count,
        depth + 1,
        total_rule_count,
    );
    errdefer {
        for (children) |*child| child.deinit(allocator);
        allocator.free(children);
    }
    const rule: CompiledRule = .{
        .operator = operator,
        .input_index = input_index,
        .pointer_id = pointer_id,
        .other_input_index = other_input_index,
        .other_pointer_id = other_pointer_id,
        .path_ids = path_ids,
        .keys = keys,
        .values = values,
        .scalar_kind = scalar_kind,
        .min_count = min_count,
        .max_count = max_count,
        .min_number = min_number,
        .max_number = max_number,
        .children = children,
    };
    try validateCachedRule(rule, input_count, pointer_count);
    return rule;
}

fn decodePathIds(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]u16 {
    const count = try decoder.readCount(1024);
    const values = try allocator.alloc(u16, count);
    errdefer allocator.free(values);
    for (values) |*value| value.* = try decoder.readU16();
    return values;
}

fn decodeKeys(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![][]u8 {
    const count = try decoder.readCount(65_536);
    const keys = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (keys[0..initialized]) |key| allocator.free(key);
        allocator.free(keys);
    }
    for (keys, 0..) |*key, index| {
        key.* = try decoder.readBytesAlloc(allocator, 4 * 1024 * 1024);
        errdefer allocator.free(key.*);
        if (!std.unicode.utf8ValidateSlice(key.*)) return error.InvalidUtf8;
        if (index != 0 and
            std.mem.order(u8, keys[index - 1], key.*) != .lt)
        {
            return error.CacheRuleKeysNotSorted;
        }
        initialized += 1;
    }
    return keys;
}

fn decodeEnumScalars(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]EnumScalar {
    const count = try decoder.readCount(65_536);
    const values = try allocator.alloc(EnumScalar, count);
    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |*value| value.deinit(allocator);
        allocator.free(values);
    }
    for (values) |*value| {
        value.* = switch (try decoder.readByte()) {
            0 => .{ .string = try decoder.readBytesAlloc(
                allocator,
                4 * 1024 * 1024,
            ) },
            1 => .{ .integer = try decoder.readI64() },
            2 => blk: {
                const number = try decoder.readF64();
                if (!std.math.isFinite(number)) {
                    return error.CacheNumberInvalid;
                }
                break :blk .{ .float = number };
            },
            3 => .{ .boolean = try decoder.readBool() },
            4 => .null,
            else => return error.CacheEnumScalarInvalid,
        };
        initialized += 1;
    }
    return values;
}

fn validateCachedRule(
    rule: CompiledRule,
    input_count: usize,
    pointer_count: usize,
) !void {
    if (rule.input_index >= input_count or
        (rule.pointer_id != null and rule.pointer_id.? >= pointer_count) or
        (rule.other_input_index != null and
            rule.other_input_index.? >= input_count) or
        (rule.other_pointer_id != null and
            rule.other_pointer_id.? >= pointer_count))
    {
        return error.CacheRuleIndexInvalid;
    }
    for (rule.path_ids) |path_id| {
        if (path_id >= pointer_count) return error.CacheRuleIndexInvalid;
    }
    if (rule.min_count != null and rule.max_count != null and
        rule.min_count.? > rule.max_count.?)
    {
        return error.InvalidRuleBounds;
    }
    if (rule.min_number != null and rule.max_number != null and
        rule.min_number.? > rule.max_number.?)
    {
        return error.InvalidRuleBounds;
    }
    switch (rule.operator) {
        .scalar_type => if (rule.scalar_kind == null) {
            return error.CacheRuleConfigurationInvalid;
        },
        .bounded_string,
        .bounded_array,
        .bounded_object,
        => if (rule.min_count == null and rule.max_count == null) {
            return error.CacheRuleConfigurationInvalid;
        },
        .bounded_number => if (rule.min_number == null and
            rule.max_number == null)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .enum_value => if (rule.values.len == 0) {
            return error.CacheRuleConfigurationInvalid;
        },
        .set_equality,
        .subset,
        .superset,
        .disjoint,
        .field_equal,
        .field_not_equal,
        .cross_input_equal,
        => if (rule.other_input_index == null or
            rule.pointer_id == null or
            rule.other_pointer_id == null)
        {
            return error.CacheRuleConfigurationInvalid;
        } else if (rule.path_ids.len > 1 or
            (rule.path_ids.len == 1 and
                rule.input_index != rule.other_input_index.?))
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .exactly_one, .at_least_one => if (rule.path_ids.len == 0) {
            return error.CacheRuleConfigurationInvalid;
        },
        .keyed_unique => if (rule.pointer_id == null or
            rule.other_pointer_id == null)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .reference_exists => if (rule.pointer_id == null or
            rule.other_input_index == null or
            rule.other_pointer_id == null or
            rule.path_ids.len != 2)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .implies => if (rule.pointer_id == null or
            rule.other_pointer_id == null or
            rule.values.len > 1)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .total_partition => if (rule.pointer_id == null or
            rule.path_ids.len < 2)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .total_mapping => if (rule.pointer_id == null or
            rule.other_pointer_id == null or
            rule.path_ids.len != 3)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .all_rules, .any_rules, .no_rules => if (rule.pointer_id == null or
            rule.children.len == 0 or rule.children.len > 64)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        else => {},
    }
    if (rule.operator != .all_rules and
        rule.operator != .any_rules and
        rule.operator != .no_rules and
        rule.children.len != 0)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    for (rule.children) |child| {
        if (child.input_index != rule.input_index or
            !isItemOperator(child.operator))
        {
            return error.CacheRuleConfigurationInvalid;
        }
        try validateCachedRule(child, input_count, pointer_count);
    }
}

fn encodeEnumScalar(
    encoder: *definition_core.cache.Encoder,
    value: EnumScalar,
) !void {
    switch (value) {
        .string => |text| {
            try encoder.writeByte(0);
            try encoder.writeBytes(text);
        },
        .integer => |number| {
            try encoder.writeByte(1);
            try encoder.writeI64(number);
        },
        .float => |number| {
            try encoder.writeByte(2);
            try encoder.writeF64(number);
        },
        .boolean => |flag| {
            try encoder.writeByte(3);
            try encoder.writeBool(flag);
        },
        .null => try encoder.writeByte(4),
    }
}

fn writeOptionalByte(
    encoder: *definition_core.cache.Encoder,
    value: ?u8,
) !void {
    try encoder.writeBool(value != null);
    if (value) |number| try encoder.writeByte(number);
}

fn readOptionalByte(
    decoder: *definition_core.cache.Decoder,
) !?u8 {
    if (!try decoder.readBool()) return null;
    return @as(?u8, try decoder.readByte());
}

fn writeOptionalU16(
    encoder: *definition_core.cache.Encoder,
    value: ?u16,
) !void {
    try encoder.writeBool(value != null);
    if (value) |number| try encoder.writeU16(number);
}

fn readOptionalU16(
    decoder: *definition_core.cache.Decoder,
) !?u16 {
    if (!try decoder.readBool()) return null;
    return @as(?u16, try decoder.readU16());
}

fn writeOptionalUsize(
    encoder: *definition_core.cache.Encoder,
    value: ?usize,
) !void {
    try encoder.writeBool(value != null);
    if (value) |number| try encoder.writeUsize(number);
}

fn readOptionalUsize(
    decoder: *definition_core.cache.Decoder,
) !?usize {
    if (!try decoder.readBool()) return null;
    return @as(?usize, try decoder.readUsize());
}

fn writeOptionalF64(
    encoder: *definition_core.cache.Encoder,
    value: ?f64,
) !void {
    try encoder.writeBool(value != null);
    if (value) |number| try encoder.writeF64(number);
}

fn readOptionalF64(
    decoder: *definition_core.cache.Decoder,
) !?f64 {
    if (!try decoder.readBool()) return null;
    const value = try decoder.readF64();
    if (!std.math.isFinite(value)) return error.CacheNumberInvalid;
    return @as(?f64, value);
}

const LoadedInput = struct {
    bytes: ?[]const u8 = null,
    parsed_json: ?std.json.Parsed(std.json.Value) = null,

    fn deinit(self: *LoadedInput) void {
        if (self.parsed_json) |*parsed| parsed.deinit();
        self.* = undefined;
    }
};

pub const Execution = struct {
    allocator: std.mem.Allocator,
    loaded: []LoadedInput,
    input_digests: ?[]InputDigest,
    diagnostics: ?definition_core.diagnostics.Collector,

    pub fn deinit(self: *Execution) void {
        for (self.loaded) |*input| input.deinit();
        self.allocator.free(self.loaded);
        if (self.input_digests) |digests| {
            for (digests) |*digest| digest.deinit(self.allocator);
            self.allocator.free(digests);
        }
        if (self.diagnostics) |*diagnostics| diagnostics.deinit();
        self.* = undefined;
    }

    pub fn isValid(self: *const Execution) bool {
        const diagnostics = self.diagnostics orelse return false;
        return diagnostics.items.items.len == 0;
    }

    pub fn inputBytes(self: *const Execution, input_index: usize) ?[]const u8 {
        if (input_index >= self.loaded.len) return null;
        return self.loaded[input_index].bytes;
    }

    pub fn inputJson(self: *const Execution, input_index: usize) ?std.json.Value {
        if (input_index >= self.loaded.len) return null;
        const parsed = self.loaded[input_index].parsed_json orelse return null;
        return parsed.value;
    }

    pub fn inputJsonPtr(
        self: *Execution,
        input_index: usize,
    ) ?*std.json.Value {
        if (input_index >= self.loaded.len) return null;
        const parsed = if (self.loaded[input_index].parsed_json) |*value|
            value
        else
            return null;
        return &parsed.value;
    }

    pub fn inputDigest(self: *const Execution, name: []const u8) ?[]const u8 {
        const digests = self.input_digests orelse return null;
        for (digests) |digest| {
            if (std.mem.eql(u8, digest.name, name)) return digest.digest;
        }
        return null;
    }

    pub fn addDiagnostic(
        self: *Execution,
        code: []const u8,
        path: []const u8,
        message: []const u8,
    ) !void {
        const diagnostics = if (self.diagnostics) |*value|
            value
        else
            return error.ExecutionAlreadyConsumed;
        try diagnostics.add(code, path, message);
    }

    pub fn takeResult(
        self: *Execution,
        allocator: std.mem.Allocator,
        definition_plan: *const definition.Plan,
    ) !Result {
        const diagnostics = self.diagnostics orelse return error.ExecutionAlreadyConsumed;
        const digests = self.input_digests orelse return error.ExecutionAlreadyConsumed;
        const definition_id = try allocator.dupe(u8, definition_plan.id);
        self.diagnostics = null;
        self.input_digests = null;
        return .{
            .definition_id = definition_id,
            .definition_digest = definition_plan.closure_digest,
            .input_digests = digests,
            .diagnostics = diagnostics,
            .valid = diagnostics.items.items.len == 0,
        };
    }
};

pub fn execute(
    allocator: std.mem.Allocator,
    validation_plan: *const Plan,
    documents: []const InputDocument,
) !Execution {
    var diagnostics = definition_core.diagnostics.Collector.init(allocator, .{
        .max_count = validation_plan.max_diagnostics,
        .max_total_bytes = 64 * 1024,
        .max_message_bytes = 2048,
    });
    errdefer diagnostics.deinit();

    const loaded = try allocator.alloc(LoadedInput, validation_plan.inputs.len);
    @memset(loaded, .{});
    errdefer {
        for (loaded) |*input| input.deinit();
        allocator.free(loaded);
    }
    const seen = try allocator.alloc(bool, validation_plan.inputs.len);
    defer allocator.free(seen);
    @memset(seen, false);

    var digests: std.ArrayList(InputDigest) = .empty;
    errdefer {
        for (digests.items) |*digest| digest.deinit(allocator);
        digests.deinit(allocator);
    }

    var total_bytes: usize = 0;
    for (documents) |document| {
        const input_index = findInput(validation_plan.inputs, document.name) orelse
            return error.UnknownInputBinding;
        if (seen[input_index]) return error.DuplicateInputBinding;
        seen[input_index] = true;
        total_bytes = std.math.add(usize, total_bytes, document.bytes.len) catch
            return error.InputBytesExceeded;
        if (document.bytes.len > validation_plan.inputs[input_index].max_bytes or
            total_bytes > validation_plan.max_input_bytes)
        {
            try diagnostics.add(
                "artifact.input-too-large",
                document.name,
                "input exceeds its declared byte bound",
            );
            continue;
        }
        loaded[input_index].bytes = document.bytes;
        {
            const digest_name = try allocator.dupe(u8, document.name);
            errdefer allocator.free(digest_name);
            const digest_value = try definition_core.canonical_json.digestBytesAlloc(
                allocator,
                document.bytes,
            );
            errdefer allocator.free(digest_value);
            try digests.append(allocator, .{
                .name = digest_name,
                .digest = digest_value,
            });
        }
        switch (validation_plan.inputs[input_index].codec) {
            .json => {
                loaded[input_index].parsed_json = std.json.parseFromSlice(
                    std.json.Value,
                    allocator,
                    document.bytes,
                    .{
                        .allocate = .alloc_always,
                        .duplicate_field_behavior = .@"error",
                    },
                ) catch {
                    try diagnostics.add(
                        "artifact.invalid-json",
                        document.name,
                        "input is not duplicate-free JSON",
                    );
                    continue;
                };
            },
            .jsonl => try validateJsonl(
                allocator,
                document.name,
                document.bytes,
                validation_plan.max_records,
                &diagnostics,
            ),
            .text => if (!std.unicode.utf8ValidateSlice(document.bytes)) {
                try diagnostics.add(
                    "artifact.invalid-utf8",
                    document.name,
                    "text input is not valid UTF-8",
                );
            },
        }
    }
    for (validation_plan.inputs, 0..) |input, index| {
        if (input.required and !seen[index]) {
            try diagnostics.add(
                "artifact.missing-input",
                input.name,
                "required input was not supplied",
            );
        }
    }
    for (validation_plan.rules) |rule| {
        try applyRule(
            allocator,
            validation_plan,
            loaded,
            rule,
            &diagnostics,
        );
    }
    std.mem.sort(InputDigest, digests.items, {}, struct {
        fn lessThan(_: void, left: InputDigest, right: InputDigest) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    const input_digests = try digests.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .loaded = loaded,
        .input_digests = input_digests,
        .diagnostics = diagnostics,
    };
}

pub fn validate(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    validation_plan: *const Plan,
    documents: []const InputDocument,
) !Result {
    var execution = try execute(allocator, validation_plan, documents);
    defer execution.deinit();
    return execution.takeResult(allocator, definition_plan);
}

fn applyRule(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    loaded: []const LoadedInput,
    rule: CompiledRule,
    diagnostics: *definition_core.diagnostics.Collector,
) !void {
    const parsed = loaded[rule.input_index].parsed_json orelse return;
    const root = parsed.value;
    const target = if (rule.pointer_id) |pointer_id|
        resolve(root, plan.pointers[pointer_id])
    else
        root;
    const path = if (rule.pointer_id) |pointer_id| plan.pointers[pointer_id].raw else "";
    const valid = switch (rule.operator) {
        .required_field => target != null,
        .optional_field => true,
        .exact_object => if (target) |value| exactObject(value, rule.keys) else false,
        .scalar_type => if (target) |value| valueHasKind(value, rule.scalar_kind.?) else false,
        .bounded_string => if (target) |value| boundedString(value, rule) else false,
        .bounded_number => if (target) |value| boundedNumber(value, rule) else false,
        .bounded_array => if (target) |value| boundedCount(value, .array, rule) else false,
        .bounded_object => if (target) |value| boundedCount(value, .object, rule) else false,
        .enum_value => if (target) |value| enumContains(rule.values, value) else false,
        .digest => if (target) |value| validateScalar(value, .digest) else false,
        .timestamp => if (target) |value| validateScalar(value, .timestamp) else false,
        .safe_identifier => if (target) |value| safeIdentifier(value, rule.max_count) else false,
        .safe_relative_path => if (target) |value| validateScalar(value, .relative_path) else false,
        .unique => if (target) |value| arrayUnique(value) else false,
        .sorted => if (target) |value| arraySorted(value) else false,
        .keyed_unique => if (target) |value|
            try keyedUnique(
                allocator,
                value,
                plan.pointers[rule.other_pointer_id.?],
                plan.max_records,
            )
        else
            false,
        .reference_exists => if (target) |value|
            try referencesExist(
                allocator,
                plan,
                loaded,
                rule,
                value,
            )
        else
            false,
        .implies => implicationHolds(plan, root, rule),
        .total_partition => try totalPartition(
            allocator,
            plan,
            root,
            rule,
        ),
        .total_mapping => try totalMapping(
            allocator,
            plan,
            root,
            rule,
        ),
        .all_rules, .any_rules, .no_rules => if (target) |value|
            try collectionRuleHolds(
                allocator,
                plan,
                rule,
                value,
            )
        else
            false,
        .set_equality,
        .subset,
        .superset,
        .disjoint,
        .field_equal,
        .field_not_equal,
        .cross_input_equal,
        => compareRule(plan, loaded, rule),
        .exactly_one, .at_least_one => countPresent(plan, root, rule),
        else => true,
    };
    if (!valid) {
        try diagnostics.add(
            rule.operator.id(),
            path,
            "artifact does not satisfy the compiled structural rule",
        );
    }
}

fn collectionRuleHolds(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: CompiledRule,
    value: std.json.Value,
) anyerror!bool {
    const items = switch (value) {
        .array => |array| array.items,
        else => return false,
    };
    if (items.len > plan.max_records) return false;
    return switch (rule.operator) {
        .all_rules => {
            for (items) |item| {
                if (!try itemRulesHold(allocator, plan, rule.children, item)) {
                    return false;
                }
            }
            return true;
        },
        .any_rules => {
            for (items) |item| {
                if (try itemRulesHold(allocator, plan, rule.children, item)) {
                    return true;
                }
            }
            return false;
        },
        .no_rules => {
            for (items) |item| {
                if (try itemRulesHold(allocator, plan, rule.children, item)) {
                    return false;
                }
            }
            return true;
        },
        else => unreachable,
    };
}

fn itemRulesHold(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rules: []const CompiledRule,
    root: std.json.Value,
) anyerror!bool {
    for (rules) |rule| {
        if (!try itemRuleHolds(allocator, plan, rule, root)) return false;
    }
    return true;
}

fn itemRuleHolds(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: CompiledRule,
    root: std.json.Value,
) anyerror!bool {
    const target = if (rule.pointer_id) |pointer_id|
        resolve(root, plan.pointers[pointer_id])
    else
        root;
    return switch (rule.operator) {
        .required_field => target != null,
        .optional_field => true,
        .exact_object => if (target) |value| exactObject(value, rule.keys) else false,
        .scalar_type => if (target) |value| valueHasKind(value, rule.scalar_kind.?) else false,
        .bounded_string => if (target) |value| boundedString(value, rule) else false,
        .bounded_number => if (target) |value| boundedNumber(value, rule) else false,
        .bounded_array => if (target) |value| boundedCount(value, .array, rule) else false,
        .bounded_object => if (target) |value| boundedCount(value, .object, rule) else false,
        .enum_value => if (target) |value| enumContains(rule.values, value) else false,
        .digest => if (target) |value| validateScalar(value, .digest) else false,
        .timestamp => if (target) |value| validateScalar(value, .timestamp) else false,
        .safe_identifier => if (target) |value| safeIdentifier(value, rule.max_count) else false,
        .safe_relative_path => if (target) |value| validateScalar(value, .relative_path) else false,
        .unique => if (target) |value| arrayUnique(value) else false,
        .sorted => if (target) |value| arraySorted(value) else false,
        .keyed_unique => if (target) |value|
            try keyedUnique(
                allocator,
                value,
                plan.pointers[rule.other_pointer_id.?],
                plan.max_records,
            )
        else
            false,
        .implies => implicationHolds(plan, root, rule),
        .set_equality,
        .subset,
        .superset,
        .disjoint,
        .field_equal,
        .field_not_equal,
        => {
            const left = resolve(
                root,
                plan.pointers[rule.pointer_id.?],
            ) orelse return false;
            const right = resolve(
                root,
                plan.pointers[rule.other_pointer_id.?],
            ) orelse return false;
            return compareValues(rule.operator, left, right);
        },
        .exactly_one, .at_least_one => countPresent(plan, root, rule),
        .all_rules, .any_rules, .no_rules => if (target) |value|
            collectionRuleHolds(allocator, plan, rule, value)
        else
            false,
        else => unreachable,
    };
}

fn compareRule(
    plan: *const Plan,
    loaded: []const LoadedInput,
    rule: CompiledRule,
) bool {
    const left_root = (loaded[rule.input_index].parsed_json orelse return false).value;
    const right_root = (loaded[rule.other_input_index.?].parsed_json orelse return false).value;
    if (rule.path_ids.len == 1) {
        const items = switch (resolve(
            left_root,
            plan.pointers[rule.path_ids[0]],
        ) orelse return false) {
            .array => |array| array.items,
            else => return false,
        };
        if (items.len > plan.max_records) return false;
        for (items) |item| {
            const left = resolve(
                item,
                plan.pointers[rule.pointer_id.?],
            ) orelse return false;
            const right = resolve(
                item,
                plan.pointers[rule.other_pointer_id.?],
            ) orelse return false;
            if (!compareValues(rule.operator, left, right)) return false;
        }
        return true;
    }
    const left = resolve(left_root, plan.pointers[rule.pointer_id.?]) orelse return false;
    const right = resolve(right_root, plan.pointers[rule.other_pointer_id.?]) orelse return false;
    return compareValues(rule.operator, left, right);
}

fn compareValues(
    operator: definition.Operator,
    left: std.json.Value,
    right: std.json.Value,
) bool {
    return switch (operator) {
        .field_equal, .cross_input_equal => valuesEqual(left, right),
        .field_not_equal => !valuesEqual(left, right),
        .set_equality => setSubset(left, right) and setSubset(right, left),
        .subset => setSubset(left, right),
        .superset => setSubset(right, left),
        .disjoint => setsDisjoint(left, right),
        else => false,
    };
}

fn countPresent(plan: *const Plan, root: std.json.Value, rule: CompiledRule) bool {
    var count: usize = 0;
    for (rule.path_ids) |pointer_id| {
        if (resolve(root, plan.pointers[pointer_id]) != null) count += 1;
    }
    return if (rule.operator == .exactly_one) count == 1 else count >= 1;
}

fn implicationHolds(
    plan: *const Plan,
    root: std.json.Value,
    rule: CompiledRule,
) bool {
    const condition = resolve(
        root,
        plan.pointers[rule.pointer_id.?],
    ) orelse return true;
    if (rule.values.len == 1 and
        !enumEqual(rule.values[0], condition))
    {
        return true;
    }
    return resolve(
        root,
        plan.pointers[rule.other_pointer_id.?],
    ) != null;
}

const PartitionEntry = struct {
    value: std.json.Value,
    admitted: bool = false,
};

fn totalPartition(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
    rule: CompiledRule,
) !bool {
    const universe_value = resolve(
        root,
        plan.pointers[rule.pointer_id.?],
    ) orelse return false;
    const universe = switch (universe_value) {
        .array => |array| array.items,
        else => return false,
    };
    if (universe.len > plan.max_records) return false;

    var index: std.AutoHashMapUnmanaged([32]u8, PartitionEntry) = .empty;
    defer index.deinit(allocator);
    for (universe) |value| {
        const digest = scalarKeyDigest(value) orelse return false;
        const result = try index.getOrPut(allocator, digest);
        if (result.found_existing) {
            if (!valuesEqual(result.value_ptr.value, value)) {
                return error.TotalPartitionDigestCollision;
            }
            return false;
        }
        result.value_ptr.* = .{ .value = value };
    }

    var admitted_count: usize = 0;
    for (rule.path_ids) |path_id| {
        const part_value = resolve(
            root,
            plan.pointers[path_id],
        ) orelse return false;
        const part = switch (part_value) {
            .array => |array| array.items,
            else => return false,
        };
        for (part) |value| {
            admitted_count = std.math.add(
                usize,
                admitted_count,
                1,
            ) catch return false;
            if (admitted_count > plan.max_records) return false;
            const digest = scalarKeyDigest(value) orelse return false;
            const entry = index.getPtr(digest) orelse return false;
            if (!valuesEqual(entry.value, value)) {
                return error.TotalPartitionDigestCollision;
            }
            if (entry.admitted) return false;
            entry.admitted = true;
        }
    }
    if (admitted_count != universe.len) return false;
    var iterator = index.valueIterator();
    while (iterator.next()) |entry| {
        if (!entry.admitted) return false;
    }
    return true;
}

const MappingSource = struct {
    value: std.json.Value,
    mapped: bool = false,
};

fn totalMapping(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
    rule: CompiledRule,
) !bool {
    const source_value = resolve(
        root,
        plan.pointers[rule.pointer_id.?],
    ) orelse return false;
    const target_value = resolve(
        root,
        plan.pointers[rule.other_pointer_id.?],
    ) orelse return false;
    const mapping_value = resolve(
        root,
        plan.pointers[rule.path_ids[0]],
    ) orelse return false;
    const sources = switch (source_value) {
        .array => |array| array.items,
        else => return false,
    };
    const targets = switch (target_value) {
        .array => |array| array.items,
        else => return false,
    };
    const mappings = switch (mapping_value) {
        .array => |array| array.items,
        else => return false,
    };
    if (sources.len > plan.max_records or
        targets.len > plan.max_records or
        mappings.len > plan.max_records or
        mappings.len != sources.len)
    {
        return false;
    }

    var source_index: std.AutoHashMapUnmanaged(
        [32]u8,
        MappingSource,
    ) = .empty;
    defer source_index.deinit(allocator);
    for (sources) |value| {
        const digest = scalarKeyDigest(value) orelse return false;
        const result = try source_index.getOrPut(allocator, digest);
        if (result.found_existing) {
            if (!valuesEqual(result.value_ptr.value, value)) {
                return error.TotalMappingDigestCollision;
            }
            return false;
        }
        result.value_ptr.* = .{ .value = value };
    }

    var target_index: std.AutoHashMapUnmanaged(
        [32]u8,
        std.json.Value,
    ) = .empty;
    defer target_index.deinit(allocator);
    for (targets) |value| {
        const digest = scalarKeyDigest(value) orelse return false;
        const result = try target_index.getOrPut(allocator, digest);
        if (result.found_existing) {
            if (!valuesEqual(result.value_ptr.*, value)) {
                return error.TotalMappingDigestCollision;
            }
            return false;
        }
        result.value_ptr.* = value;
    }

    for (mappings) |mapping| {
        const from = resolve(
            mapping,
            plan.pointers[rule.path_ids[1]],
        ) orelse return false;
        const to = resolve(
            mapping,
            plan.pointers[rule.path_ids[2]],
        ) orelse return false;
        const from_digest = scalarKeyDigest(from) orelse return false;
        const source = source_index.getPtr(from_digest) orelse return false;
        if (!valuesEqual(source.value, from)) {
            return error.TotalMappingDigestCollision;
        }
        if (source.mapped) return false;
        source.mapped = true;

        const to_digest = scalarKeyDigest(to) orelse return false;
        const target = target_index.get(to_digest) orelse return false;
        if (!valuesEqual(target, to)) {
            return error.TotalMappingDigestCollision;
        }
    }
    var iterator = source_index.valueIterator();
    while (iterator.next()) |source| {
        if (!source.mapped) return false;
    }
    return true;
}

fn resolve(root: std.json.Value, pointer: Pointer) ?std.json.Value {
    return definition_core.json_pointer.lookup(root, pointer);
}

fn exactObject(value: std.json.Value, keys: []const []u8) bool {
    const object = switch (value) {
        .object => |object| object,
        else => return false,
    };
    if (object.count() != keys.len) return false;
    for (keys) |key| if (!object.contains(key)) return false;
    return true;
}

fn valueHasKind(value: std.json.Value, kind: JsonKind) bool {
    return switch (kind) {
        .string => value == .string,
        .integer => value == .integer,
        .number => value == .integer or value == .float or value == .number_string,
        .boolean => value == .bool,
        .array => value == .array,
        .object => value == .object,
        .null => value == .null,
    };
}

fn boundedString(value: std.json.Value, rule: CompiledRule) bool {
    const text = switch (value) {
        .string => |text| text,
        else => return false,
    };
    return withinCount(text.len, rule);
}

fn boundedNumber(value: std.json.Value, rule: CompiledRule) bool {
    const number = jsonNumber(value) orelse return false;
    if (rule.min_number) |minimum| if (number < minimum) return false;
    if (rule.max_number) |maximum| if (number > maximum) return false;
    return true;
}

fn boundedCount(value: std.json.Value, kind: JsonKind, rule: CompiledRule) bool {
    const count = switch (kind) {
        .array => switch (value) {
            .array => |array| array.items.len,
            else => return false,
        },
        .object => switch (value) {
            .object => |object| object.count(),
            else => return false,
        },
        else => unreachable,
    };
    return withinCount(count, rule);
}

fn withinCount(count: usize, rule: CompiledRule) bool {
    if (rule.min_count) |minimum| if (count < minimum) return false;
    if (rule.max_count) |maximum| if (count > maximum) return false;
    return true;
}

fn enumContains(values: []const EnumScalar, value: std.json.Value) bool {
    for (values) |candidate| if (enumEqual(candidate, value)) return true;
    return false;
}

fn enumEqual(candidate: EnumScalar, value: std.json.Value) bool {
    return switch (candidate) {
        .string => |text| value == .string and std.mem.eql(u8, text, value.string),
        .integer => |number| value == .integer and number == value.integer,
        .float => |number| jsonNumber(value) != null and number == jsonNumber(value).?,
        .boolean => |flag| value == .bool and flag == value.bool,
        .null => value == .null,
    };
}

fn validateScalar(value: std.json.Value, kind: definition_core.scalar.Kind) bool {
    const text = switch (value) {
        .string => |text| text,
        else => return false,
    };
    definition_core.scalar.validateString(kind, text) catch return false;
    return true;
}

fn safeIdentifier(value: std.json.Value, maximum: ?usize) bool {
    const text = switch (value) {
        .string => |text| text,
        else => return false,
    };
    definition_core.json.safeIdentifier(text, maximum orelse 128) catch return false;
    return true;
}

fn arrayUnique(value: std.json.Value) bool {
    const items = switch (value) {
        .array => |array| array.items,
        else => return false,
    };
    for (items, 0..) |left, index| {
        for (items[index + 1 ..]) |right| if (valuesEqual(left, right)) return false;
    }
    return true;
}

fn arraySorted(value: std.json.Value) bool {
    const items = switch (value) {
        .array => |array| array.items,
        else => return false,
    };
    if (items.len < 2) return true;
    for (items[1..], 1..) |item, index| {
        if (valueOrder(items[index - 1], item) == .gt) return false;
    }
    return true;
}

fn keyedUnique(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key_pointer: Pointer,
    max_records: usize,
) !bool {
    const items = switch (value) {
        .array => |array| array.items,
        else => return false,
    };
    if (items.len > max_records) return false;
    var seen: std.AutoHashMapUnmanaged([32]u8, std.json.Value) = .empty;
    defer seen.deinit(allocator);
    for (items) |item| {
        const key = resolve(item, key_pointer) orelse return false;
        const digest = scalarKeyDigest(key) orelse return false;
        const result = try seen.getOrPut(allocator, digest);
        if (result.found_existing) {
            if (valuesEqual(result.value_ptr.*, key)) return false;
            return error.KeyedUniqueDigestCollision;
        }
        result.value_ptr.* = key;
    }
    return true;
}

fn referencesExist(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    loaded: []const LoadedInput,
    rule: CompiledRule,
    source_value: std.json.Value,
) !bool {
    const source_items = switch (source_value) {
        .array => |array| array.items,
        else => return false,
    };
    if (source_items.len > plan.max_records) return false;
    const target_root =
        (loaded[rule.other_input_index.?].parsed_json orelse return false).value;
    const target_value = resolve(
        target_root,
        plan.pointers[rule.path_ids[0]],
    ) orelse return false;
    const target_items = switch (target_value) {
        .array => |array| array.items,
        else => return false,
    };
    if (target_items.len > plan.max_records) return false;

    var index: std.AutoHashMapUnmanaged([32]u8, std.json.Value) = .empty;
    defer index.deinit(allocator);
    for (target_items) |item| {
        const key = resolve(
            item,
            plan.pointers[rule.path_ids[1]],
        ) orelse return false;
        const digest = scalarKeyDigest(key) orelse return false;
        const result = try index.getOrPut(allocator, digest);
        if (result.found_existing) {
            if (!valuesEqual(result.value_ptr.*, key)) {
                return error.ReferenceKeyDigestCollision;
            }
        } else {
            result.value_ptr.* = key;
        }
    }

    var reference_count: usize = 0;
    for (source_items) |item| {
        const references = resolve(
            item,
            plan.pointers[rule.other_pointer_id.?],
        ) orelse return false;
        switch (references) {
            .array => |array| for (array.items) |reference| {
                reference_count += 1;
                if (reference_count > plan.max_records or
                    !try scalarIndexContains(&index, reference))
                {
                    return false;
                }
            },
            else => {
                reference_count += 1;
                if (reference_count > plan.max_records or
                    !try scalarIndexContains(&index, references))
                {
                    return false;
                }
            },
        }
    }
    return true;
}

fn scalarIndexContains(
    index: *const std.AutoHashMapUnmanaged([32]u8, std.json.Value),
    key: std.json.Value,
) !bool {
    const digest = scalarKeyDigest(key) orelse return false;
    const indexed = index.get(digest) orelse return false;
    if (!valuesEqual(indexed, key)) {
        return error.ReferenceKeyDigestCollision;
    }
    return true;
}

fn scalarKeyDigest(value: std.json.Value) ?[32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    switch (value) {
        .null => hasher.update("null"),
        .bool => |flag| {
            hasher.update("bool:");
            hasher.update(if (flag) "true" else "false");
        },
        .string => |text| {
            hasher.update("string:");
            hasher.update(text);
        },
        .integer, .float, .number_string => {
            const number = jsonNumber(value) orelse return null;
            if (!std.math.isFinite(number)) return null;
            const normalized: f64 = if (number == 0) 0 else number;
            const bits: u64 = @bitCast(normalized);
            hasher.update("number:");
            hasher.update(std.mem.asBytes(&bits));
        },
        .array, .object => return null,
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn setSubset(left: std.json.Value, right: std.json.Value) bool {
    const left_items = switch (left) {
        .array => |array| array.items,
        else => return false,
    };
    const right_items = switch (right) {
        .array => |array| array.items,
        else => return false,
    };
    for (left_items) |item| {
        var found = false;
        for (right_items) |candidate| {
            if (valuesEqual(item, candidate)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn setsDisjoint(left: std.json.Value, right: std.json.Value) bool {
    const left_items = switch (left) {
        .array => |array| array.items,
        else => return false,
    };
    const right_items = switch (right) {
        .array => |array| array.items,
        else => return false,
    };
    for (left_items) |item| {
        for (right_items) |candidate| if (valuesEqual(item, candidate)) return false;
    }
    return true;
}

fn valuesEqual(left: std.json.Value, right: std.json.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) {
        const left_number = jsonNumber(left) orelse return false;
        const right_number = jsonNumber(right) orelse return false;
        return left_number == right_number;
    }
    return switch (left) {
        .null => true,
        .bool => |value| value == right.bool,
        .integer => |value| value == right.integer,
        .float => |value| value == right.float,
        .number_string => |value| std.mem.eql(u8, value, right.number_string),
        .string => |value| std.mem.eql(u8, value, right.string),
        .array => |array| blk: {
            if (array.items.len != right.array.items.len) break :blk false;
            for (array.items, right.array.items) |a, b| {
                if (!valuesEqual(a, b)) break :blk false;
            }
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != right.object.count()) break :blk false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const other = right.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!valuesEqual(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn valueOrder(left: std.json.Value, right: std.json.Value) std.math.Order {
    if (left == .string and right == .string) return std.mem.order(u8, left.string, right.string);
    if (left == .bool and right == .bool) {
        if (left.bool == right.bool) return .eq;
        return if (!left.bool and right.bool) .lt else .gt;
    }
    const left_number = jsonNumber(left) orelse return .gt;
    const right_number = jsonNumber(right) orelse return .lt;
    return std.math.order(left_number, right_number);
}

fn jsonNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        .number_string => |number| std.fmt.parseFloat(f64, number) catch null,
        else => null,
    };
}

fn validateJsonl(
    allocator: std.mem.Allocator,
    name: []const u8,
    bytes: []const u8,
    max_records: usize,
    diagnostics: *definition_core.diagnostics.Collector,
) !void {
    var record_count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trimEnd(u8, line_with_cr, "\r");
        if (line.len == 0) continue;
        record_count += 1;
        if (record_count > max_records) {
            try diagnostics.add(
                "artifact.too-many-records",
                name,
                "JSONL input exceeds its declared record bound",
            );
            return;
        }
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .duplicate_field_behavior = .@"error" },
        ) catch {
            try diagnostics.add(
                "artifact.invalid-jsonl",
                name,
                "JSONL input contains an invalid or duplicate-key row",
            );
            return;
        };
        parsed.deinit();
    }
}

fn parseStringSet(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) ![][]u8 {
    const items = try definition_core.json.array(raw);
    if (items.items.len > 65_536) return error.TooManyRuleValues;
    const out = try allocator.alloc([]u8, items.items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |value| allocator.free(value);
        allocator.free(out);
    }
    for (items.items, 0..) |item, index| {
        out[index] = try allocator.dupe(u8, try definition_core.json.string(item));
        initialized += 1;
    }
    std.mem.sort([]u8, out, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    for (out[1..], 1..) |value, index| {
        if (std.mem.eql(u8, out[index - 1], value)) return error.DuplicateRuleValue;
    }
    return out;
}

fn parseEnumValues(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) ![]EnumScalar {
    const items = try definition_core.json.array(raw);
    if (items.items.len == 0 or items.items.len > 65_536) return error.InvalidEnumValues;
    const out = try allocator.alloc(EnumScalar, items.items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |*value| value.deinit(allocator);
        allocator.free(out);
    }
    for (items.items, 0..) |item, index| {
        out[index] = try parseEnumScalar(allocator, item);
        initialized += 1;
    }
    return out;
}

fn parseEnumScalar(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !EnumScalar {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .integer => |number| .{ .integer = number },
        .float => |number| if (std.math.isFinite(number))
            .{ .float = number }
        else
            error.InvalidEnumValue,
        .number_string => |number| number: {
            const parsed = std.fmt.parseFloat(f64, number) catch
                return error.InvalidEnumValue;
            if (!std.math.isFinite(parsed)) return error.InvalidEnumValue;
            break :number .{ .float = parsed };
        },
        .bool => |flag| .{ .boolean = flag },
        .null => .null,
        else => error.InvalidEnumValue,
    };
}

fn optionalUnsigned(object: std.json.ObjectMap, name: []const u8) !?usize {
    const raw = object.get(name) orelse return null;
    return try definition_core.json.unsigned(raw);
}

fn optionalNumber(object: std.json.ObjectMap, name: []const u8) !?f64 {
    const raw = object.get(name) orelse return null;
    return jsonNumber(raw) orelse error.ExpectedNumber;
}

fn findInput(inputs: []const definition.Input, name: []const u8) ?usize {
    for (inputs, 0..) |input, index| {
        if (std.mem.eql(u8, input.name, name)) return index;
    }
    return null;
}

fn cloneInputs(
    allocator: std.mem.Allocator,
    source: []const definition.Input,
) ![]definition.Input {
    const out = try allocator.alloc(definition.Input, source.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |*input| input.deinit(allocator);
        allocator.free(out);
    }
    for (source, 0..) |input, index| {
        out[index] = .{
            .name = try allocator.dupe(u8, input.name),
            .codec = input.codec,
            .required = input.required,
            .max_bytes = input.max_bytes,
        };
        initialized += 1;
    }
    return out;
}

fn isValidationOperator(operator: definition.Operator) bool {
    return switch (operator) {
        .exact_object,
        .required_field,
        .optional_field,
        .scalar_type,
        .bounded_string,
        .bounded_number,
        .bounded_array,
        .bounded_object,
        .enum_value,
        .digest,
        .timestamp,
        .safe_identifier,
        .safe_relative_path,
        .unique,
        .sorted,
        .set_equality,
        .subset,
        .superset,
        .disjoint,
        .exactly_one,
        .at_least_one,
        .all_rules,
        .any_rules,
        .no_rules,
        .field_equal,
        .field_not_equal,
        .cross_input_equal,
        .keyed_unique,
        .reference_exists,
        .implies,
        .total_partition,
        .total_mapping,
        => true,
        else => false,
    };
}

fn isItemOperator(operator: definition.Operator) bool {
    return switch (operator) {
        .exact_object,
        .required_field,
        .optional_field,
        .scalar_type,
        .bounded_string,
        .bounded_number,
        .bounded_array,
        .bounded_object,
        .enum_value,
        .digest,
        .timestamp,
        .safe_identifier,
        .safe_relative_path,
        .unique,
        .sorted,
        .set_equality,
        .subset,
        .superset,
        .disjoint,
        .exactly_one,
        .at_least_one,
        .keyed_unique,
        .implies,
        .all_rules,
        .any_rules,
        .no_rules,
        => true,
        else => false,
    };
}

fn validateForAllocationFailure(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    validation_plan: *const Plan,
    bytes: []const u8,
) !void {
    var result = try validate(
        allocator,
        definition_plan,
        validation_plan,
        &.{.{ .name = "record", .bytes = bytes }},
    );
    defer result.deinit(allocator);
}

fn compileForAllocationFailure(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
) !void {
    var plan = compile(allocator, definition_plan) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer plan.deinit(allocator);
}

fn decodeForAllocationFailure(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !void {
    var decoder = definition_core.cache.Decoder.init(payload);
    var plan = decodeCache(allocator, &decoder) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer plan.deinit(allocator);
    try decoder.finish();
}

test "compiled validation plan accepts valid structure and rejects invalid structure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{
        \\  "schema":"ledger-artifact-definition/v1",
        \\  "id":"example/record",
        \\  "owner":"example",
        \\  "requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object","scalar-type","enum","safe-identifier","unique","sorted","field-equal","keyed-unique","reference-exists","disjoint","implies","total-partition","total-mapping","all","any","none"]},
        \\  "inputs":{"record":{"codec":"json","max_bytes":4096}},
        \\  "canonicalization":{},
        \\  "shape":{"rules":[
        \\    {"op":"exact-object","path":"","keys":["schema","record_id","status","tags","mirror","items","links","meta","universe","accepted","rejected","targets","mappings"]},
        \\    {"op":"scalar-type","path":"/record_id","type":"string"},
        \\    {"op":"safe-identifier","path":"/record_id","max":64},
        \\    {"op":"enum","path":"/status","values":["open","closed"]},
        \\    {"op":"unique","path":"/tags"},
        \\    {"op":"sorted","path":"/tags"},
        \\    {"op":"keyed-unique","path":"/items","key":"/id"},
        \\    {"op":"reference-exists","path":"/links","reference":"/item_refs","target":"/items","key":"/id"},
        \\    {"op":"all","path":"/items","rules":[
        \\      {"op":"exact-object","keys":["id","labels"]},
        \\      {"op":"scalar-type","path":"/id","type":"string"},
        \\      {"op":"all","path":"/labels","rules":[{"op":"scalar-type","type":"string"}]},
        \\      {"op":"none","path":"/labels","rules":[{"op":"enum","values":["forbidden"]}]}
        \\    ]},
        \\    {"op":"any","path":"/items","rules":[{"op":"enum","path":"/id","values":["item-2"]}]},
        \\    {"op":"none","path":"/items","rules":[{"op":"enum","path":"/id","values":["forbidden"]}]}
        \\  ]},
        \\  "constraints":[
        \\    {"op":"field-equal","left":"/status","right":"/mirror"},
        \\    {"op":"disjoint","path":"/links","left":"/expected","right":"/prohibited"},
        \\    {"op":"implies","if":"/status","equals":"closed","then":"/meta/closure"},
        \\    {"op":"total-partition","universe":"/universe","parts":["/accepted","/rejected"]},
        \\    {"op":"total-mapping","source":"/universe","target":"/targets","mapping":"/mappings","from":"/from","to":"/to"}
        \\  ],
        \\  "identity":{},
        \\  "storage":{"kind":"pure"},
        \\  "operations":{},
        \\  "projections":{},
        \\  "bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":10,"max_output_bytes":4096,"max_diagnostics":16,"max_reducer_states":16}
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
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "artifact.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var plan = try compile(std.testing.allocator, &definition_plan);
    defer plan.deinit(std.testing.allocator);
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        8 * 1024 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(&plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(std.testing.allocator, &decoder);
    defer cached.deinit(std.testing.allocator);
    try decoder.finish();
    try std.testing.expectEqual(plan.inputs.len, cached.inputs.len);
    try std.testing.expectEqual(plan.pointers.len, cached.pointers.len);
    try std.testing.expectEqual(plan.rules.len, cached.rules.len);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileForAllocationFailure,
        .{&definition_plan},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeForAllocationFailure,
        .{payload},
    );

    const valid_bytes =
        "{\"schema\":\"example/v1\",\"record_id\":\"record-1\",\"status\":\"open\",\"tags\":[\"a\",\"b\"],\"mirror\":\"open\",\"items\":[{\"id\":\"item-1\",\"labels\":[\"a\"]},{\"id\":\"item-2\",\"labels\":[\"b\"]}],\"links\":[{\"item_refs\":[\"item-1\",\"item-2\"],\"expected\":[\"a\"],\"prohibited\":[\"b\"]}],\"meta\":{},\"universe\":[\"a\",\"b\"],\"accepted\":[\"a\"],\"rejected\":[\"b\"],\"targets\":[\"x\",\"y\"],\"mappings\":[{\"from\":\"a\",\"to\":\"x\"},{\"from\":\"b\",\"to\":\"y\"}]}";
    var valid = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = valid_bytes,
        }},
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(valid.valid);
    try std.testing.expect(!valid.authority_granted);
    try std.testing.expect(!valid.storage_mutated);

    var invalid = try validate(
        std.testing.allocator,
        &definition_plan,
        &plan,
        &.{.{
            .name = "record",
            .bytes = "{\"schema\":\"example/v1\",\"record_id\":\"bad id\",\"status\":\"closed\",\"tags\":[\"b\",\"a\",\"a\"],\"mirror\":\"open\",\"items\":[{\"id\":\"item-1\",\"labels\":[1,\"forbidden\"]},{\"id\":\"item-1\",\"labels\":[]}],\"links\":[{\"item_refs\":[\"missing\"],\"expected\":[\"same\"],\"prohibited\":[\"same\"]}],\"meta\":{},\"universe\":[\"a\",\"b\"],\"accepted\":[\"a\",\"b\"],\"rejected\":[\"b\"],\"targets\":[\"x\",\"y\"],\"mappings\":[{\"from\":\"a\",\"to\":\"x\"},{\"from\":\"a\",\"to\":\"y\"}],\"extra\":true}",
        }},
    );
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expect(!invalid.valid);
    try std.testing.expect(invalid.diagnostics.items.items.len >= 5);
    var saw_implication = false;
    var saw_partition = false;
    var saw_mapping = false;
    var saw_all = false;
    var saw_any = false;
    for (invalid.diagnostics.items.items) |diagnostic| {
        saw_implication = saw_implication or
            std.mem.eql(u8, diagnostic.code, "implies");
        saw_partition = saw_partition or
            std.mem.eql(u8, diagnostic.code, "total-partition");
        saw_mapping = saw_mapping or
            std.mem.eql(u8, diagnostic.code, "total-mapping");
        saw_all = saw_all or std.mem.eql(u8, diagnostic.code, "all");
        saw_any = saw_any or std.mem.eql(u8, diagnostic.code, "any");
    }
    try std.testing.expect(saw_implication);
    try std.testing.expect(saw_partition);
    try std.testing.expect(saw_mapping);
    try std.testing.expect(saw_all);
    try std.testing.expect(saw_any);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        validateForAllocationFailure,
        .{ &definition_plan, &plan, valid_bytes },
    );
}

test "validation reports missing and malformed inputs without granting authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/input","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":[]},"inputs":{"record":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":1024,"max_records":1,"max_output_bytes":1024,"max_diagnostics":8,"max_reducer_states":1}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "artifact.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var plan = try compile(std.testing.allocator, &definition_plan);
    defer plan.deinit(std.testing.allocator);

    var missing = try validate(
        std.testing.allocator,
        &definition_plan,
        &plan,
        &.{},
    );
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(!missing.valid);

    var malformed = try validate(
        std.testing.allocator,
        &definition_plan,
        &plan,
        &.{.{ .name = "record", .bytes = "{\"a\":1,\"a\":2}" }},
    );
    defer malformed.deinit(std.testing.allocator);
    try std.testing.expect(!malformed.valid);
    try std.testing.expect(!malformed.authority_granted);
    try std.testing.expect(!malformed.storage_mutated);
}
