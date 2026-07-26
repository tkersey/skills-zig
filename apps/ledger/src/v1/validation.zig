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

const IdentifierStyle = enum {
    portable,
    lowercase_component,

    fn parse(text: []const u8) !IdentifierStyle {
        if (std.mem.eql(u8, text, "portable")) return .portable;
        if (std.mem.eql(u8, text, "lowercase-component")) {
            return .lowercase_component;
        }
        return error.UnsupportedIdentifierStyle;
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

const CompiledVariant = struct {
    kind: ?JsonKind = null,
    tag_value: ?EnumScalar = null,
    rules: []CompiledRule,

    fn deinit(self: *CompiledVariant, allocator: std.mem.Allocator) void {
        if (self.tag_value) |*value| value.deinit(allocator);
        for (self.rules) |*rule| rule.deinit(allocator);
        allocator.free(self.rules);
        self.* = undefined;
    }
};

const CompiledFormatPart = union(enum) {
    literal: []u8,
    parent: u16,
    item: u16,

    fn deinit(self: *CompiledFormatPart, allocator: std.mem.Allocator) void {
        if (self.* == .literal) allocator.free(self.literal);
        self.* = undefined;
    }
};

const CompiledRule = struct {
    operator: definition.Operator,
    input_index: u8,
    pointer_id: ?u16,
    import_index: ?u16 = null,
    imported_plan: ?*Plan = null,
    other_input_index: ?u8 = null,
    other_pointer_id: ?u16 = null,
    path_ids: []u16,
    keys: [][]u8,
    optional_keys: [][]u8,
    values: []EnumScalar,
    scalar_kind: ?JsonKind = null,
    min_count: ?usize = null,
    max_count: ?usize = null,
    trimmed_min_count: ?usize = null,
    min_number: ?f64 = null,
    max_number: ?f64 = null,
    identifier_style: IdentifierStyle = .portable,
    allow_root: bool = true,
    case_insensitive: bool = false,
    total_coverage: bool = false,
    reject_self_reference: bool = false,
    ignore_null_references: bool = false,
    children: []CompiledRule,
    variants: []CompiledVariant,
    format_parts: []CompiledFormatPart,

    fn deinit(self: *CompiledRule, allocator: std.mem.Allocator) void {
        allocator.free(self.path_ids);
        for (self.keys) |key| allocator.free(key);
        allocator.free(self.keys);
        for (self.optional_keys) |key| allocator.free(key);
        allocator.free(self.optional_keys);
        for (self.values) |*value| value.deinit(allocator);
        allocator.free(self.values);
        for (self.children) |*child| child.deinit(allocator);
        allocator.free(self.children);
        for (self.variants) |*variant| variant.deinit(allocator);
        allocator.free(self.variants);
        for (self.format_parts) |*part| part.deinit(allocator);
        allocator.free(self.format_parts);
        if (self.imported_plan) |plan| {
            plan.deinit(allocator);
            allocator.destroy(plan);
        }
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
            .optional_keys = try self.allocator.alloc([]u8, 0),
            .values = try self.allocator.alloc(EnumScalar, 0),
            .children = try self.allocator.alloc(CompiledRule, 0),
            .variants = try self.allocator.alloc(CompiledVariant, 0),
            .format_parts = try self.allocator.alloc(CompiledFormatPart, 0),
        };
        errdefer rule.deinit(self.allocator);

        switch (source.operator) {
            .exact_object => try compileExactObjectRule(
                self.allocator,
                object,
                true,
                &rule,
            ),
            .optional_field => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "path", "rules" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "path" },
                );
                if (object.get("rules")) |raw_rules| {
                    rule.children = try self.compileItemRules(
                        raw_rules,
                        input_index,
                        0,
                    );
                }
            },
            .scalar_type => rule.scalar_kind = try JsonKind.parse(
                try definition_core.json.requiredString(object, "type"),
            ),
            .bounded_array,
            .bounded_object,
            => {
                rule.min_count = try optionalUnsigned(object, "min");
                rule.max_count = try optionalUnsigned(object, "max");
                if (rule.min_count == null and rule.max_count == null) {
                    return error.MissingRuleBound;
                }
                if (rule.min_count != null and rule.max_count != null and
                    rule.min_count.? > rule.max_count.?)
                {
                    return error.InvalidRuleBounds;
                }
            },
            .bounded_string => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "path", "min", "max", "trimmed_min" },
                );
                rule.min_count = try optionalUnsigned(object, "min");
                rule.max_count = try optionalUnsigned(object, "max");
                rule.trimmed_min_count = try optionalUnsigned(
                    object,
                    "trimmed_min",
                );
                if (rule.min_count == null and rule.max_count == null and
                    rule.trimmed_min_count == null)
                {
                    return error.MissingRuleBound;
                }
                if (rule.min_count != null and rule.max_count != null and
                    rule.min_count.? > rule.max_count.?)
                {
                    return error.InvalidRuleBounds;
                }
                if (rule.trimmed_min_count != null and
                    rule.max_count != null and
                    rule.trimmed_min_count.? > rule.max_count.?)
                {
                    return error.InvalidRuleBounds;
                }
            },
            .safe_identifier => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "path", "min", "max", "style" },
                );
                rule.min_count = try optionalUnsigned(object, "min");
                rule.max_count = try optionalUnsigned(object, "max");
                if (rule.min_count != null and rule.max_count != null and
                    rule.min_count.? > rule.max_count.?)
                {
                    return error.InvalidRuleBounds;
                }
                if (object.get("style")) |raw| {
                    rule.identifier_style = try IdentifierStyle.parse(
                        try definition_core.json.string(raw),
                    );
                }
            },
            .safe_relative_path => {
                try compileRelativePathRule(self.allocator, object, &rule);
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
            .path_format => try self.compilePathFormat(object, &rule),
            .exactly_one, .at_least_one => rule.path_ids = try self.parsePaths(
                try definition_core.json.field(object, "paths"),
            ),
            .one_of, .all_rules, .any_rules, .no_rules => {
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
            .tagged_union => try self.compileTaggedUnion(
                object,
                input_index,
                0,
                true,
                &rule,
            ),
            .definition_ref => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "path", "definition" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "path", "definition" },
                );
                const import_index = source.import_index orelse
                    return error.ImportedDefinitionIndexMissing;
                if (import_index >= self.definition_plan.imports.len) {
                    return error.ImportedDefinitionIndexInvalid;
                }
                const imported_definition =
                    &self.definition_plan.imports[import_index];
                if (!std.mem.eql(
                    u8,
                    imported_definition.id,
                    try definition_core.json.requiredString(
                        object,
                        "definition",
                    ),
                )) return error.ImportedDefinitionIdMismatch;
                if (imported_definition.storage_kind != .pure or
                    imported_definition.inputs.len != 1 or
                    imported_definition.inputs[0].codec != .json or
                    !imported_definition.inputs[0].required)
                {
                    return error.ImportedDefinitionNotReusable;
                }
                const imported_plan = try self.allocator.create(Plan);
                var imported_plan_initialized = false;
                var imported_plan_owned = true;
                errdefer if (imported_plan_owned) {
                    if (imported_plan_initialized) {
                        imported_plan.deinit(self.allocator);
                    }
                    self.allocator.destroy(imported_plan);
                };
                imported_plan.* = try compile(
                    self.allocator,
                    imported_definition,
                );
                imported_plan_initialized = true;
                for (imported_plan.rules) |imported_rule| {
                    if (imported_rule.input_index != 0 or
                        (imported_rule.other_input_index != null and
                            imported_rule.other_input_index.? != 0) or
                        !isItemOperator(imported_rule.operator))
                    {
                        return error.UnsupportedImportedDefinitionRule;
                    }
                }
                rule.import_index = import_index;
                rule.imported_plan = imported_plan;
                imported_plan_owned = false;
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
                        "target_items",
                        "target_rules",
                        "key",
                        "coverage",
                        "self_reference",
                        "ignore_null",
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
                    try definition_core.json.string(
                        try definition_core.json.field(
                            object,
                            "reference",
                        ),
                    ),
                );
                const target_items = if (object.get("target_items")) |raw|
                    try self.internPointer(
                        try definition_core.json.string(raw),
                    )
                else
                    null;
                rule.path_ids = try self.allocator.alloc(
                    u16,
                    if (target_items == null) 2 else 3,
                );
                rule.path_ids[0] = try self.internPointer(
                    try definition_core.json.requiredString(object, "target"),
                );
                rule.path_ids[1] = try self.internPointer(
                    try definition_core.json.string(
                        try definition_core.json.field(object, "key"),
                    ),
                );
                if (target_items) |pointer_id| {
                    rule.path_ids[2] = pointer_id;
                }
                if (object.get("target_rules")) |raw_rules| {
                    rule.children = try self.compileItemRules(
                        raw_rules,
                        rule.other_input_index.?,
                        0,
                    );
                }
                if (object.get("coverage")) |raw_coverage| {
                    const coverage = try definition_core.json.string(
                        raw_coverage,
                    );
                    if (!std.mem.eql(u8, coverage, "all-targets")) {
                        return error.UnsupportedReferenceCoverage;
                    }
                    rule.total_coverage = true;
                }
                if (object.get("self_reference")) |raw_policy| {
                    const policy = try definition_core.json.string(
                        raw_policy,
                    );
                    if (!std.mem.eql(u8, policy, "reject")) {
                        return error.UnsupportedSelfReferencePolicy;
                    }
                    if (rule.other_input_index.? != rule.input_index or
                        rule.path_ids[0] != rule.pointer_id.?)
                    {
                        return error.SelfReferenceRequiresOneCollection;
                    }
                    rule.reject_self_reference = true;
                }
                rule.ignore_null_references =
                    try optionalBoolean(object, "ignore_null") orelse false;
            },
            else => {},
        }
        try self.rules.append(self.allocator, rule);
    }

    fn compilePathFormat(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) anyerror!void {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "input", "path", "items", "target", "fragments" },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "op", "path", "items", "target", "fragments" },
        );
        if (rule.pointer_id == null) return error.PathFormatCollectionMissing;
        rule.other_pointer_id = try self.internPointer(
            try definition_core.json.string(
                try definition_core.json.field(object, "items"),
            ),
        );
        rule.path_ids = try self.allocator.alloc(u16, 1);
        rule.path_ids[0] = try self.internPointer(
            try definition_core.json.string(
                try definition_core.json.field(object, "target"),
            ),
        );
        const raw_fragments = try definition_core.json.array(
            try definition_core.json.field(object, "fragments"),
        );
        if (raw_fragments.items.len == 0 or
            raw_fragments.items.len > 32)
        {
            return error.PathFormatFragmentCountInvalid;
        }
        const parts = try self.allocator.alloc(
            CompiledFormatPart,
            raw_fragments.items.len,
        );
        var initialized: usize = 0;
        var literal_bytes: usize = 0;
        errdefer {
            for (parts[0..initialized]) |*part| {
                part.deinit(self.allocator);
            }
            self.allocator.free(parts);
        }
        for (raw_fragments.items, 0..) |raw_fragment, index| {
            const fragment = try definition_core.json.object(raw_fragment);
            if (fragment.count() != 1) {
                return error.PathFormatFragmentInvalid;
            }
            if (fragment.get("literal")) |raw_literal| {
                const literal = try definition_core.json.string(raw_literal);
                if (literal.len == 0) {
                    return error.PathFormatLiteralEmpty;
                }
                literal_bytes = std.math.add(
                    usize,
                    literal_bytes,
                    literal.len,
                ) catch return error.PathFormatLiteralBytesExceeded;
                if (literal_bytes > 4096) {
                    return error.PathFormatLiteralBytesExceeded;
                }
                parts[index] = .{
                    .literal = try self.allocator.dupe(u8, literal),
                };
            } else if (fragment.get("parent")) |raw_parent| {
                parts[index] = .{
                    .parent = try self.internPointer(
                        try definition_core.json.string(raw_parent),
                    ),
                };
            } else if (fragment.get("item")) |raw_item| {
                parts[index] = .{
                    .item = try self.internPointer(
                        try definition_core.json.string(raw_item),
                    ),
                };
            } else {
                return error.PathFormatFragmentInvalid;
            }
            initialized += 1;
        }
        rule.format_parts = parts;
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
        if (!isItemOperator(operator) or operator == .definition_ref) {
            return error.UnsupportedItemOperator;
        }
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
            .optional_keys = try self.allocator.alloc([]u8, 0),
            .values = try self.allocator.alloc(EnumScalar, 0),
            .children = try self.allocator.alloc(CompiledRule, 0),
            .variants = try self.allocator.alloc(CompiledVariant, 0),
            .format_parts = try self.allocator.alloc(CompiledFormatPart, 0),
        };
        errdefer rule.deinit(self.allocator);
        switch (operator) {
            .exact_object => try compileExactObjectRule(
                self.allocator,
                object,
                false,
                &rule,
            ),
            .optional_field => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "rules" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "path" },
                );
                if (object.get("rules")) |raw_rules| {
                    rule.children = try self.compileItemRules(
                        raw_rules,
                        input_index,
                        depth + 1,
                    );
                }
            },
            .required_field,
            .digest,
            .timestamp,
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
            .bounded_array,
            .bounded_object,
            => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "min", "max" },
                );
                rule.min_count = try optionalUnsigned(object, "min");
                rule.max_count = try optionalUnsigned(object, "max");
                if (rule.min_count == null and rule.max_count == null) {
                    return error.MissingRuleBound;
                }
                if (rule.min_count != null and rule.max_count != null and
                    rule.min_count.? > rule.max_count.?)
                {
                    return error.InvalidRuleBounds;
                }
            },
            .bounded_string => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "min", "max", "trimmed_min" },
                );
                rule.min_count = try optionalUnsigned(object, "min");
                rule.max_count = try optionalUnsigned(object, "max");
                rule.trimmed_min_count = try optionalUnsigned(
                    object,
                    "trimmed_min",
                );
                if (rule.min_count == null and rule.max_count == null and
                    rule.trimmed_min_count == null)
                {
                    return error.MissingRuleBound;
                }
                if (rule.min_count != null and rule.max_count != null and
                    rule.min_count.? > rule.max_count.?)
                {
                    return error.InvalidRuleBounds;
                }
                if (rule.trimmed_min_count != null and
                    rule.max_count != null and
                    rule.trimmed_min_count.? > rule.max_count.?)
                {
                    return error.InvalidRuleBounds;
                }
            },
            .safe_identifier => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "min", "max", "style" },
                );
                rule.min_count = try optionalUnsigned(object, "min");
                rule.max_count = try optionalUnsigned(object, "max");
                if (rule.min_count != null and rule.max_count != null and
                    rule.min_count.? > rule.max_count.?)
                {
                    return error.InvalidRuleBounds;
                }
                if (object.get("style")) |raw| {
                    rule.identifier_style = try IdentifierStyle.parse(
                        try definition_core.json.string(raw),
                    );
                }
            },
            .safe_relative_path => {
                try compileRelativePathRule(self.allocator, object, &rule);
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
            .one_of, .all_rules, .any_rules, .no_rules => {
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
            .tagged_union => try self.compileTaggedUnion(
                object,
                input_index,
                depth,
                false,
                &rule,
            ),
            else => unreachable,
        }
        return rule;
    }

    fn compileTaggedUnion(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        depth: usize,
        allow_input: bool,
        rule: *CompiledRule,
    ) anyerror!void {
        if (allow_input) {
            try definition_core.json.requireExactKeys(
                object,
                &.{ "op", "input", "path", "tag", "variants" },
            );
        } else {
            try definition_core.json.requireExactKeys(
                object,
                &.{ "op", "path", "tag", "variants" },
            );
        }
        try definition_core.json.requireFields(
            object,
            &.{ "op", "path", "variants" },
        );
        if (object.get("tag")) |raw_tag| {
            rule.other_pointer_id = try self.internPointer(
                try definition_core.json.string(raw_tag),
            );
        }
        const raw_variants = try definition_core.json.array(
            try definition_core.json.field(object, "variants"),
        );
        if (raw_variants.items.len == 0 or raw_variants.items.len > 64) {
            return error.TaggedUnionVariantCountInvalid;
        }
        const variants = try self.allocator.alloc(
            CompiledVariant,
            raw_variants.items.len,
        );
        var initialized: usize = 0;
        errdefer {
            for (variants[0..initialized]) |*variant| {
                variant.deinit(self.allocator);
            }
            self.allocator.free(variants);
        }
        for (raw_variants.items, 0..) |raw_variant, index| {
            const variant_object =
                try definition_core.json.object(raw_variant);
            if (rule.other_pointer_id != null) {
                try definition_core.json.requireExactKeys(
                    variant_object,
                    &.{ "value", "rules" },
                );
                try definition_core.json.requireFields(
                    variant_object,
                    &.{ "value", "rules" },
                );
            } else {
                try definition_core.json.requireExactKeys(
                    variant_object,
                    &.{ "kind", "rules" },
                );
                try definition_core.json.requireFields(
                    variant_object,
                    &.{ "kind", "rules" },
                );
            }
            var variant: CompiledVariant = .{
                .kind = if (rule.other_pointer_id == null)
                    try JsonKind.parse(
                        try definition_core.json.requiredString(
                            variant_object,
                            "kind",
                        ),
                    )
                else
                    null,
                .tag_value = if (rule.other_pointer_id != null)
                    try parseEnumScalar(
                        self.allocator,
                        try definition_core.json.field(
                            variant_object,
                            "value",
                        ),
                    )
                else
                    null,
                .rules = try self.compileVariantRules(
                    try definition_core.json.field(variant_object, "rules"),
                    input_index,
                    depth + 1,
                ),
            };
            errdefer variant.deinit(self.allocator);
            for (variants[0..initialized]) |prior| {
                if ((variant.kind != null and prior.kind == variant.kind) or
                    (variant.tag_value != null and
                        prior.tag_value != null and
                        enumScalarsEqual(
                            variant.tag_value.?,
                            prior.tag_value.?,
                        )))
                {
                    return error.DuplicateTaggedUnionVariant;
                }
            }
            variants[index] = variant;
            initialized += 1;
        }
        rule.variants = variants;
    }

    fn compileVariantRules(
        self: *Builder,
        raw: std.json.Value,
        input_index: u8,
        depth: usize,
    ) anyerror![]CompiledRule {
        const items = try definition_core.json.array(raw);
        if (items.items.len == 0) {
            return self.allocator.alloc(CompiledRule, 0);
        }
        return self.compileItemRules(raw, input_index, depth);
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
) anyerror!Plan {
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
    try encoder.writeU16(13);
    try encodeCachePlan(plan, encoder, 0);
}

fn encodeCachePlan(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
    depth: usize,
) anyerror!void {
    if (depth > 32) return error.ImportDepthExceeded;
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
    for (plan.rules) |rule| {
        try encodeCompiledRule(encoder, rule, depth);
    }
    try encoder.writeUsize(plan.max_input_bytes);
    try encoder.writeUsize(plan.max_records);
    try encoder.writeUsize(plan.max_diagnostics);
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 13) {
        return error.LedgerValidationCacheVersionMismatch;
    }
    var imported_plan_count: usize = 0;
    return decodeCachePlan(
        allocator,
        decoder,
        0,
        &imported_plan_count,
    );
}

fn decodeCachePlan(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    depth: usize,
    imported_plan_count: *usize,
) anyerror!Plan {
    if (depth > 32) return error.CacheImportDepthExceeded;
    imported_plan_count.* = std.math.add(
        usize,
        imported_plan_count.*,
        1,
    ) catch return error.CacheImportCountExceeded;
    if (imported_plan_count.* > 128) return error.CacheImportCountExceeded;
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
        depth,
        imported_plan_count,
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
) anyerror!void {
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
    if (rule.operator == .definition_ref) {
        const import_index = rule.import_index orelse
            return error.CacheValidationPlanMismatch;
        if (import_index >= definition_plan.imports.len or
            rule.imported_plan == null)
        {
            return error.CacheValidationPlanMismatch;
        }
        try validateCachePlan(
            rule.imported_plan.?,
            &definition_plan.imports[import_index],
        );
    } else if (rule.import_index != null or rule.imported_plan != null) {
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
    for (rule.variants) |variant| {
        for (variant.rules) |variant_rule| {
            if (variant_rule.input_index != rule.input_index or
                !isItemOperator(variant_rule.operator))
            {
                return error.CacheValidationPlanMismatch;
            }
            try validateRuleAgainstDefinition(
                variant_rule,
                definition_plan,
            );
        }
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
    depth: usize,
) anyerror!void {
    try encoder.writeEnum(rule.operator);
    try encoder.writeByte(rule.input_index);
    try writeOptionalU16(encoder, rule.pointer_id);
    try writeOptionalU16(encoder, rule.import_index);
    try writeOptionalByte(encoder, rule.other_input_index);
    try writeOptionalU16(encoder, rule.other_pointer_id);
    try encoder.writeCount(rule.path_ids.len);
    for (rule.path_ids) |path_id| try encoder.writeU16(path_id);
    try encoder.writeCount(rule.keys.len);
    for (rule.keys) |key| try encoder.writeBytes(key);
    try encoder.writeCount(rule.optional_keys.len);
    for (rule.optional_keys) |key| try encoder.writeBytes(key);
    try encoder.writeCount(rule.values.len);
    for (rule.values) |value| try encodeEnumScalar(encoder, value);
    try encoder.writeBool(rule.scalar_kind != null);
    if (rule.scalar_kind) |kind| try encoder.writeEnum(kind);
    try writeOptionalUsize(encoder, rule.min_count);
    try writeOptionalUsize(encoder, rule.max_count);
    try writeOptionalUsize(encoder, rule.trimmed_min_count);
    try writeOptionalF64(encoder, rule.min_number);
    try writeOptionalF64(encoder, rule.max_number);
    try encoder.writeEnum(rule.identifier_style);
    try encoder.writeBool(rule.allow_root);
    try encoder.writeBool(rule.case_insensitive);
    try encoder.writeBool(rule.total_coverage);
    try encoder.writeBool(rule.reject_self_reference);
    try encoder.writeBool(rule.ignore_null_references);
    try encoder.writeCount(rule.children.len);
    for (rule.children) |child| {
        try encodeCompiledRule(encoder, child, depth);
    }
    try encoder.writeCount(rule.variants.len);
    for (rule.variants) |variant| {
        if (variant.kind) |kind| {
            try encoder.writeByte(0);
            try encoder.writeEnum(kind);
        } else if (variant.tag_value) |tag_value| {
            try encoder.writeByte(1);
            try encodeEnumScalar(encoder, tag_value);
        } else {
            return error.TaggedUnionVariantInvalid;
        }
        try encoder.writeCount(variant.rules.len);
        for (variant.rules) |variant_rule| {
            try encodeCompiledRule(encoder, variant_rule, depth);
        }
    }
    try encoder.writeCount(rule.format_parts.len);
    for (rule.format_parts) |part| {
        switch (part) {
            .literal => |literal| {
                try encoder.writeByte(0);
                try encoder.writeBytes(literal);
            },
            .parent => |pointer_id| {
                try encoder.writeByte(1);
                try encoder.writeU16(pointer_id);
            },
            .item => |pointer_id| {
                try encoder.writeByte(2);
                try encoder.writeU16(pointer_id);
            },
        }
    }
    try encoder.writeBool(rule.imported_plan != null);
    if (rule.imported_plan) |imported_plan| {
        try encodeCachePlan(imported_plan, encoder, depth + 1);
    }
}

fn decodeCacheRules(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    input_count: usize,
    pointer_count: usize,
    depth: usize,
    total_rule_count: *usize,
    plan_depth: usize,
    imported_plan_count: *usize,
) anyerror![]CompiledRule {
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
            plan_depth,
            imported_plan_count,
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
    plan_depth: usize,
    imported_plan_count: *usize,
) anyerror!CompiledRule {
    const operator = try decoder.readEnum(definition.Operator);
    const input_index = try decoder.readByte();
    const pointer_id = try readOptionalU16(decoder);
    const import_index = try readOptionalU16(decoder);
    const other_input_index = try readOptionalByte(decoder);
    const other_pointer_id = try readOptionalU16(decoder);
    const path_ids = try decodePathIds(allocator, decoder);
    errdefer allocator.free(path_ids);
    const keys = try decodeKeys(allocator, decoder);
    errdefer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }
    const optional_keys = try decodeKeys(allocator, decoder);
    errdefer {
        for (optional_keys) |key| allocator.free(key);
        allocator.free(optional_keys);
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
    const trimmed_min_count = try readOptionalUsize(decoder);
    const min_number = try readOptionalF64(decoder);
    const max_number = try readOptionalF64(decoder);
    const identifier_style = try decoder.readEnum(IdentifierStyle);
    const allow_root = try decoder.readBool();
    const case_insensitive = try decoder.readBool();
    const total_coverage = try decoder.readBool();
    const reject_self_reference = try decoder.readBool();
    const ignore_null_references = try decoder.readBool();
    const children = try decodeCacheRules(
        allocator,
        decoder,
        input_count,
        pointer_count,
        depth + 1,
        total_rule_count,
        plan_depth,
        imported_plan_count,
    );
    errdefer {
        for (children) |*child| child.deinit(allocator);
        allocator.free(children);
    }
    const variant_count = try decoder.readCount(64);
    const variants = try allocator.alloc(CompiledVariant, variant_count);
    var variants_initialized: usize = 0;
    errdefer {
        for (variants[0..variants_initialized]) |*variant| {
            variant.deinit(allocator);
        }
        allocator.free(variants);
    }
    for (variants) |*variant| {
        const kind_or_tag = try decoder.readByte();
        var tag_value: ?EnumScalar = null;
        errdefer if (tag_value) |*value| value.deinit(allocator);
        const kind: ?JsonKind = switch (kind_or_tag) {
            0 => try decoder.readEnum(JsonKind),
            1 => tag: {
                tag_value = try decodeEnumScalar(allocator, decoder);
                break :tag null;
            },
            else => return error.CacheTaggedUnionVariantInvalid,
        };
        const variant_rules = try decodeCacheRules(
            allocator,
            decoder,
            input_count,
            pointer_count,
            depth + 1,
            total_rule_count,
            plan_depth,
            imported_plan_count,
        );
        errdefer {
            for (variant_rules) |*variant_rule| {
                variant_rule.deinit(allocator);
            }
            allocator.free(variant_rules);
        }
        variant.* = .{
            .kind = kind,
            .tag_value = tag_value,
            .rules = variant_rules,
        };
        tag_value = null;
        variants_initialized += 1;
    }
    const format_part_count = try decoder.readCount(32);
    const format_parts = try allocator.alloc(
        CompiledFormatPart,
        format_part_count,
    );
    var format_parts_initialized: usize = 0;
    errdefer {
        for (format_parts[0..format_parts_initialized]) |*part| {
            part.deinit(allocator);
        }
        allocator.free(format_parts);
    }
    var literal_bytes: usize = 0;
    for (format_parts) |*part| {
        part.* = switch (try decoder.readByte()) {
            0 => literal: {
                const text = try decoder.readBytesAlloc(allocator, 4096);
                literal_bytes = std.math.add(
                    usize,
                    literal_bytes,
                    text.len,
                ) catch {
                    allocator.free(text);
                    return error.CachePathFormatLiteralBytesExceeded;
                };
                if (text.len == 0 or literal_bytes > 4096) {
                    allocator.free(text);
                    return error.CachePathFormatLiteralBytesExceeded;
                }
                break :literal .{ .literal = text };
            },
            1 => .{ .parent = try decoder.readU16() },
            2 => .{ .item = try decoder.readU16() },
            else => return error.CachePathFormatPartInvalid,
        };
        format_parts_initialized += 1;
    }
    const imported_plan = if (try decoder.readBool()) blk: {
        const plan = try allocator.create(Plan);
        errdefer allocator.destroy(plan);
        plan.* = try decodeCachePlan(
            allocator,
            decoder,
            plan_depth + 1,
            imported_plan_count,
        );
        break :blk plan;
    } else null;
    errdefer if (imported_plan) |plan| {
        plan.deinit(allocator);
        allocator.destroy(plan);
    };
    const rule: CompiledRule = .{
        .operator = operator,
        .input_index = input_index,
        .pointer_id = pointer_id,
        .import_index = import_index,
        .imported_plan = imported_plan,
        .other_input_index = other_input_index,
        .other_pointer_id = other_pointer_id,
        .path_ids = path_ids,
        .keys = keys,
        .optional_keys = optional_keys,
        .values = values,
        .scalar_kind = scalar_kind,
        .min_count = min_count,
        .max_count = max_count,
        .trimmed_min_count = trimmed_min_count,
        .min_number = min_number,
        .max_number = max_number,
        .identifier_style = identifier_style,
        .allow_root = allow_root,
        .case_insensitive = case_insensitive,
        .total_coverage = total_coverage,
        .reject_self_reference = reject_self_reference,
        .ignore_null_references = ignore_null_references,
        .children = children,
        .variants = variants,
        .format_parts = format_parts,
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
        value.* = try decodeEnumScalar(allocator, decoder);
        initialized += 1;
    }
    return values;
}

fn decodeEnumScalar(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !EnumScalar {
    return switch (try decoder.readByte()) {
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
    if (rule.trimmed_min_count != null and rule.max_count != null and
        rule.trimmed_min_count.? > rule.max_count.?)
    {
        return error.InvalidRuleBounds;
    }
    if (rule.min_number != null and rule.max_number != null and
        rule.min_number.? > rule.max_number.?)
    {
        return error.InvalidRuleBounds;
    }
    switch (rule.operator) {
        .optional_field => if (rule.pointer_id == null or
            rule.children.len > 64)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .scalar_type => if (rule.scalar_kind == null) {
            return error.CacheRuleConfigurationInvalid;
        },
        .bounded_array,
        .bounded_object,
        => if (rule.min_count == null and rule.max_count == null) {
            return error.CacheRuleConfigurationInvalid;
        },
        .bounded_string => if (rule.min_count == null and
            rule.max_count == null and rule.trimmed_min_count == null)
        {
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
        .safe_relative_path => {
            if (rule.keys.len > 64) {
                return error.CacheRuleConfigurationInvalid;
            }
            for (rule.keys) |root| {
                definition_core.json.repositoryRelativePath(
                    root,
                    false,
                ) catch return error.CacheRuleConfigurationInvalid;
            }
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
            (rule.path_ids.len != 2 and rule.path_ids.len != 3))
        {
            return error.CacheRuleConfigurationInvalid;
        } else if (rule.reject_self_reference and rule.path_ids.len != 2) {
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
        .path_format => if (rule.pointer_id == null or
            rule.other_pointer_id == null or
            rule.path_ids.len != 1 or
            rule.format_parts.len == 0 or
            rule.format_parts.len > 32)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .one_of, .all_rules, .any_rules, .no_rules => if (rule.pointer_id == null or
            rule.children.len == 0 or rule.children.len > 64)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .tagged_union => if (rule.pointer_id == null or
            rule.variants.len == 0 or rule.variants.len > 64)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .definition_ref => if (rule.pointer_id == null or
            rule.import_index == null or
            rule.imported_plan == null or
            rule.imported_plan.?.inputs.len != 1 or
            rule.imported_plan.?.inputs[0].codec != .json or
            !rule.imported_plan.?.inputs[0].required)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        else => {},
    }
    if (rule.operator != .definition_ref and
        (rule.import_index != null or rule.imported_plan != null))
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .safe_identifier and
        rule.identifier_style != .portable)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .bounded_string and
        rule.trimmed_min_count != null)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .safe_relative_path and
        (!rule.allow_root or rule.case_insensitive))
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .reference_exists and
        (rule.total_coverage or rule.reject_self_reference))
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.reject_self_reference and
        (rule.other_input_index.? != rule.input_index or
            rule.path_ids[0] != rule.pointer_id.?))
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .exact_object and
        rule.operator != .safe_relative_path and
        rule.keys.len != 0)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .exact_object and rule.optional_keys.len != 0) {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator == .exact_object) {
        for (rule.keys) |required| {
            for (rule.optional_keys) |optional| {
                if (std.mem.eql(u8, required, optional)) {
                    return error.CacheRuleConfigurationInvalid;
                }
            }
        }
    }
    if (rule.operator != .optional_field and
        rule.operator != .one_of and
        rule.operator != .all_rules and
        rule.operator != .any_rules and
        rule.operator != .no_rules and
        rule.operator != .reference_exists and
        rule.children.len != 0)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .tagged_union and rule.variants.len != 0) {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .path_format and rule.format_parts.len != 0) {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .reference_exists and
        rule.ignore_null_references)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    var format_literal_bytes: usize = 0;
    for (rule.format_parts) |part| {
        switch (part) {
            .literal => |literal| {
                if (literal.len == 0) {
                    return error.CacheRuleConfigurationInvalid;
                }
                format_literal_bytes = std.math.add(
                    usize,
                    format_literal_bytes,
                    literal.len,
                ) catch return error.CacheRuleConfigurationInvalid;
                if (format_literal_bytes > 4096) {
                    return error.CacheRuleConfigurationInvalid;
                }
            },
            .parent, .item => |pointer_id| {
                if (pointer_id >= pointer_count) {
                    return error.CacheRuleIndexInvalid;
                }
            },
        }
    }
    for (rule.children) |child| {
        if (child.input_index != rule.input_index or
            !isItemOperator(child.operator))
        {
            return error.CacheRuleConfigurationInvalid;
        }
        try validateCachedRule(child, input_count, pointer_count);
    }
    for (rule.variants, 0..) |variant, index| {
        if ((rule.other_pointer_id == null and
            (variant.kind == null or variant.tag_value != null)) or
            (rule.other_pointer_id != null and
                (variant.kind != null or variant.tag_value == null)))
        {
            return error.CacheRuleConfigurationInvalid;
        }
        for (rule.variants[0..index]) |prior| {
            if ((variant.kind != null and prior.kind == variant.kind) or
                (variant.tag_value != null and
                    prior.tag_value != null and
                    enumScalarsEqual(
                        variant.tag_value.?,
                        prior.tag_value.?,
                    )))
            {
                return error.CacheRuleConfigurationInvalid;
            }
        }
        for (variant.rules) |variant_rule| {
            if (variant_rule.input_index != rule.input_index or
                !isItemOperator(variant_rule.operator))
            {
                return error.CacheRuleConfigurationInvalid;
            }
            try validateCachedRule(
                variant_rule,
                input_count,
                pointer_count,
            );
        }
    }
    if (rule.imported_plan) |imported_plan| {
        for (imported_plan.rules) |imported_rule| {
            if (imported_rule.input_index != 0 or
                (imported_rule.other_input_index != null and
                    imported_rule.other_input_index.? != 0) or
                !isItemOperator(imported_rule.operator))
            {
                return error.CacheRuleConfigurationInvalid;
            }
        }
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
        .optional_field => if (target) |value|
            rule.children.len == 0 or
                try itemRulesHold(
                    allocator,
                    plan,
                    rule.children,
                    value,
                )
        else
            true,
        .exact_object => if (target) |value| exactObject(value, rule) else false,
        .scalar_type => if (target) |value| valueHasKind(value, rule.scalar_kind.?) else false,
        .bounded_string => if (target) |value| boundedString(value, rule) else false,
        .bounded_number => if (target) |value| boundedNumber(value, rule) else false,
        .bounded_array => if (target) |value| boundedCount(value, .array, rule) else false,
        .bounded_object => if (target) |value| boundedCount(value, .object, rule) else false,
        .enum_value => if (target) |value| enumContains(rule.values, value) else false,
        .digest => if (target) |value| validateScalar(value, .digest) else false,
        .timestamp => if (target) |value| validateScalar(value, .timestamp) else false,
        .safe_identifier => if (target) |value| safeIdentifier(value, rule) else false,
        .safe_relative_path => if (target) |value| safeRelativePath(value, rule) else false,
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
        .path_format => if (target) |value|
            formattedFieldsHold(plan, rule, value)
        else
            false,
        .one_of => if (target) |value|
            try oneOfRulesHold(allocator, plan, rule, value)
        else
            false,
        .tagged_union => if (target) |value|
            try taggedUnionHolds(allocator, plan, rule, value)
        else
            false,
        .definition_ref => if (target) |value|
            try importedPlanHolds(
                allocator,
                rule.imported_plan.?,
                value,
            )
        else
            false,
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

fn oneOfRulesHold(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: CompiledRule,
    value: std.json.Value,
) anyerror!bool {
    var matches: usize = 0;
    for (rule.children) |child| {
        if (try itemRuleHolds(allocator, plan, child, value)) {
            matches += 1;
            if (matches > 1) return false;
        }
    }
    return matches == 1;
}

fn formattedFieldsHold(
    plan: *const Plan,
    rule: CompiledRule,
    value: std.json.Value,
) bool {
    const parents = switch (value) {
        .array => |array| array.items,
        else => return false,
    };
    if (parents.len > plan.max_records) return false;
    var item_count: usize = 0;
    for (parents) |parent| {
        const items_value = resolve(
            parent,
            plan.pointers[rule.other_pointer_id.?],
        ) orelse return false;
        const items = switch (items_value) {
            .array => |array| array.items,
            else => return false,
        };
        item_count = std.math.add(
            usize,
            item_count,
            items.len,
        ) catch return false;
        if (item_count > plan.max_records) return false;
        for (items) |item| {
            const target_value = resolve(
                item,
                plan.pointers[rule.path_ids[0]],
            ) orelse return false;
            const target = switch (target_value) {
                .string => |text| text,
                else => return false,
            };
            var offset: usize = 0;
            for (rule.format_parts) |part| {
                const fragment = switch (part) {
                    .literal => |literal| literal,
                    .parent => |pointer_id| switch (resolve(
                        parent,
                        plan.pointers[pointer_id],
                    ) orelse return false) {
                        .string => |text| text,
                        else => return false,
                    },
                    .item => |pointer_id| switch (resolve(
                        item,
                        plan.pointers[pointer_id],
                    ) orelse return false) {
                        .string => |text| text,
                        else => return false,
                    },
                };
                const end = std.math.add(
                    usize,
                    offset,
                    fragment.len,
                ) catch return false;
                if (end > target.len or
                    !std.mem.eql(u8, target[offset..end], fragment))
                {
                    return false;
                }
                offset = end;
            }
            if (offset != target.len) return false;
        }
    }
    return true;
}

fn taggedUnionHolds(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: CompiledRule,
    value: std.json.Value,
) anyerror!bool {
    if (rule.other_pointer_id) |tag_pointer_id| {
        const tag = resolve(
            value,
            plan.pointers[tag_pointer_id],
        ) orelse return false;
        for (rule.variants) |variant| {
            if (enumEqual(variant.tag_value.?, tag)) {
                return itemRulesHold(
                    allocator,
                    plan,
                    variant.rules,
                    value,
                );
            }
        }
        return false;
    }
    for (rule.variants) |variant| {
        if (valueHasKind(value, variant.kind.?)) {
            return itemRulesHold(
                allocator,
                plan,
                variant.rules,
                value,
            );
        }
    }
    return false;
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
        .optional_field => if (target) |value|
            rule.children.len == 0 or
                try itemRulesHold(
                    allocator,
                    plan,
                    rule.children,
                    value,
                )
        else
            true,
        .exact_object => if (target) |value| exactObject(value, rule) else false,
        .scalar_type => if (target) |value| valueHasKind(value, rule.scalar_kind.?) else false,
        .bounded_string => if (target) |value| boundedString(value, rule) else false,
        .bounded_number => if (target) |value| boundedNumber(value, rule) else false,
        .bounded_array => if (target) |value| boundedCount(value, .array, rule) else false,
        .bounded_object => if (target) |value| boundedCount(value, .object, rule) else false,
        .enum_value => if (target) |value| enumContains(rule.values, value) else false,
        .digest => if (target) |value| validateScalar(value, .digest) else false,
        .timestamp => if (target) |value| validateScalar(value, .timestamp) else false,
        .safe_identifier => if (target) |value| safeIdentifier(value, rule) else false,
        .safe_relative_path => if (target) |value| safeRelativePath(value, rule) else false,
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
        .one_of => if (target) |value|
            oneOfRulesHold(allocator, plan, rule, value)
        else
            false,
        .tagged_union => if (target) |value|
            taggedUnionHolds(allocator, plan, rule, value)
        else
            false,
        .definition_ref => if (target) |value|
            importedPlanHolds(allocator, rule.imported_plan.?, value)
        else
            false,
        .all_rules, .any_rules, .no_rules => if (target) |value|
            collectionRuleHolds(allocator, plan, rule, value)
        else
            false,
        else => unreachable,
    };
}

fn importedPlanHolds(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
) anyerror!bool {
    for (plan.rules) |rule| {
        if (!try itemRuleHolds(allocator, plan, rule, root)) return false;
    }
    return true;
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

fn exactObject(value: std.json.Value, rule: CompiledRule) bool {
    const object = switch (value) {
        .object => |object| object,
        else => return false,
    };
    if (object.count() < rule.keys.len or
        object.count() > rule.keys.len + rule.optional_keys.len)
    {
        return false;
    }
    for (rule.keys) |key| if (!object.contains(key)) return false;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!containsString(rule.keys, entry.key_ptr.*) and
            !containsString(rule.optional_keys, entry.key_ptr.*))
        {
            return false;
        }
    }
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
    if (!withinCount(text.len, rule)) return false;
    if (rule.trimmed_min_count) |minimum| {
        if (std.mem.trim(u8, text, " \t\r\n").len < minimum) return false;
    }
    return true;
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

fn enumScalarsEqual(left: EnumScalar, right: EnumScalar) bool {
    return switch (left) {
        .string => |text| right == .string and
            std.mem.eql(u8, text, right.string),
        .integer => |number| right == .integer and number == right.integer,
        .float => |number| right == .float and number == right.float,
        .boolean => |flag| right == .boolean and flag == right.boolean,
        .null => right == .null,
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

fn safeIdentifier(value: std.json.Value, rule: CompiledRule) bool {
    const text = switch (value) {
        .string => |text| text,
        else => return false,
    };
    if (rule.min_count) |minimum| if (text.len < minimum) return false;
    const maximum = rule.max_count orelse 128;
    return switch (rule.identifier_style) {
        .portable => portable: {
            definition_core.json.safeIdentifier(text, maximum) catch
                break :portable false;
            break :portable true;
        },
        .lowercase_component => lowercase: {
            if (text.len == 0 or text.len > maximum) break :lowercase false;
            for (text, 0..) |byte, index| {
                const alphanumeric =
                    std.ascii.isLower(byte) or std.ascii.isDigit(byte);
                if (!alphanumeric and
                    byte != '-' and byte != '_' and byte != '.')
                {
                    break :lowercase false;
                }
                if (index == 0 and !alphanumeric) break :lowercase false;
            }
            break :lowercase true;
        },
    };
}

fn safeRelativePath(value: std.json.Value, rule: CompiledRule) bool {
    const text = switch (value) {
        .string => |text| text,
        else => return false,
    };
    definition_core.json.repositoryRelativePath(
        text,
        rule.allow_root,
    ) catch return false;
    for (rule.keys) |root| {
        const exact = if (rule.case_insensitive)
            std.ascii.eqlIgnoreCase(text, root)
        else
            std.mem.eql(u8, text, root);
        const descendant = text.len > root.len and text[root.len] == '/' and
            (if (rule.case_insensitive)
                std.ascii.eqlIgnoreCase(text[0..root.len], root)
            else
                std.mem.eql(u8, text[0..root.len], root));
        if (exact or descendant) return false;
    }
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

const ReferenceTarget = struct {
    value: std.json.Value,
    referenced: bool = false,
};

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
    const target_parents = switch (target_value) {
        .array => |array| array.items,
        else => return false,
    };
    if (target_parents.len > plan.max_records) return false;

    var index: std.AutoHashMapUnmanaged([32]u8, ReferenceTarget) = .empty;
    defer index.deinit(allocator);
    var target_count: usize = 0;
    for (target_parents) |parent| {
        if (rule.path_ids.len == 3) {
            const nested_value = resolve(
                parent,
                plan.pointers[rule.path_ids[2]],
            ) orelse return false;
            const nested_items = switch (nested_value) {
                .array => |array| array.items,
                else => return false,
            };
            target_count = std.math.add(
                usize,
                target_count,
                nested_items.len,
            ) catch return false;
            if (target_count > plan.max_records) return false;
            for (nested_items) |item| {
                if (!try indexReferenceTarget(
                    allocator,
                    plan,
                    rule,
                    item,
                    &index,
                )) return false;
            }
        } else {
            target_count += 1;
            if (target_count > plan.max_records or
                !try indexReferenceTarget(
                    allocator,
                    plan,
                    rule,
                    parent,
                    &index,
                ))
            {
                return false;
            }
        }
    }

    var reference_count: usize = 0;
    for (source_items) |item| {
        const source_key = if (rule.reject_self_reference)
            resolve(item, plan.pointers[rule.path_ids[1]]) orelse
                return false
        else
            null;
        const references = resolve(
            item,
            plan.pointers[rule.other_pointer_id.?],
        ) orelse continue;
        switch (references) {
            .array => |array| for (array.items) |reference| {
                if (rule.ignore_null_references and reference == .null) {
                    continue;
                }
                reference_count += 1;
                if (reference_count > plan.max_records or
                    !try markScalarReference(
                        &index,
                        reference,
                        source_key,
                    ))
                {
                    return false;
                }
            },
            else => {
                if (rule.ignore_null_references and references == .null) {
                    continue;
                }
                reference_count += 1;
                if (reference_count > plan.max_records or
                    !try markScalarReference(
                        &index,
                        references,
                        source_key,
                    ))
                {
                    return false;
                }
            },
        }
    }
    if (rule.total_coverage) {
        var iterator = index.valueIterator();
        while (iterator.next()) |target| {
            if (!target.referenced) return false;
        }
    }
    return true;
}

fn indexReferenceTarget(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: CompiledRule,
    item: std.json.Value,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
) !bool {
    if (rule.children.len != 0 and
        !try itemRulesHold(allocator, plan, rule.children, item))
    {
        return true;
    }
    const key = resolve(
        item,
        plan.pointers[rule.path_ids[1]],
    ) orelse return false;
    const digest = scalarKeyDigest(key) orelse return false;
    const result = try index.getOrPut(allocator, digest);
    if (result.found_existing) {
        if (!valuesEqual(result.value_ptr.value, key)) {
            return error.ReferenceKeyDigestCollision;
        }
    } else {
        result.value_ptr.* = .{ .value = key };
    }
    return true;
}

fn markScalarReference(
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    key: std.json.Value,
    self_key: ?std.json.Value,
) !bool {
    if (self_key) |value| {
        if (valuesEqual(value, key)) return false;
    }
    const digest = scalarKeyDigest(key) orelse return false;
    const indexed = index.getPtr(digest) orelse return false;
    if (!valuesEqual(indexed.value, key)) {
        return error.ReferenceKeyDigestCollision;
    }
    indexed.referenced = true;
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

fn compileRelativePathRule(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
    try definition_core.json.requireExactKeys(object, &.{
        "op",
        "input",
        "path",
        "allow_root",
        "reserved_roots",
        "case_insensitive_reserved",
    });
    rule.allow_root = try optionalBoolean(object, "allow_root") orelse true;
    rule.case_insensitive =
        try optionalBoolean(object, "case_insensitive_reserved") orelse false;
    if (object.get("reserved_roots")) |raw| {
        const roots = try definition_core.json.array(raw);
        if (roots.items.len > 64) return error.TooManyReservedPathRoots;
        rule.keys = try parseStringSet(allocator, raw);
        for (rule.keys) |root| {
            try definition_core.json.repositoryRelativePath(root, false);
        }
    }
}

fn compileExactObjectRule(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    allow_input: bool,
    rule: *CompiledRule,
) !void {
    if (allow_input) {
        try definition_core.json.requireExactKeys(
            object,
            &.{
                "op",
                "input",
                "path",
                "keys",
                "required_keys",
                "optional_keys",
            },
        );
    } else {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "path", "keys", "required_keys", "optional_keys" },
        );
    }
    if (object.get("keys")) |raw| {
        if (object.contains("required_keys") or
            object.contains("optional_keys"))
        {
            return error.AmbiguousExactObjectKeys;
        }
        rule.keys = try parseStringSet(allocator, raw);
        return;
    }
    const required = object.get("required_keys") orelse
        return error.MissingExactObjectKeys;
    rule.keys = try parseStringSet(allocator, required);
    if (object.get("optional_keys")) |raw| {
        rule.optional_keys = try parseStringSet(allocator, raw);
    }
    for (rule.keys) |required_key| {
        if (containsString(rule.optional_keys, required_key)) {
            return error.OverlappingExactObjectKeys;
        }
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

fn containsString(values: []const []u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
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

fn optionalBoolean(object: std.json.ObjectMap, name: []const u8) !?bool {
    const raw = object.get(name) orelse return null;
    return try definition_core.json.boolean(raw);
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
        .tagged_union,
        .one_of,
        .definition_ref,
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
        .path_format,
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
        .tagged_union,
        .one_of,
        .definition_ref,
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
        \\  "requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object","optional-field","scalar-type","enum","safe-identifier","unique","sorted","field-equal","keyed-unique","reference-exists","disjoint","implies","total-partition","total-mapping","path-format","all","any","none"]},
        \\  "inputs":{"record":{"codec":"json","max_bytes":4096}},
        \\  "canonicalization":{},
        \\  "shape":{"rules":[
        \\    {"op":"exact-object","path":"","keys":["schema","record_id","status","tags","mirror","items","groups","links","optional_links","containers","selected","meta","universe","ordering","accepted","rejected","targets","mappings"]},
        \\    {"op":"scalar-type","path":"/record_id","type":"string"},
        \\    {"op":"safe-identifier","path":"/record_id","max":64},
        \\    {"op":"enum","path":"/status","values":["open","closed"]},
        \\    {"op":"unique","path":"/tags"},
        \\    {"op":"sorted","path":"/tags"},
        \\    {"op":"unique","path":"/ordering"},
        \\    {"op":"keyed-unique","path":"/items","key":"/id"},
        \\    {"op":"reference-exists","path":"/links","reference":"/item_refs","target":"/items","key":"/id"},
        \\    {"op":"reference-exists","path":"/links","reference":"/optional_target","target":"/items","key":"/id","ignore_null":true},
        \\    {"op":"reference-exists","path":"/optional_links","reference":"/item_refs","target":"/items","key":"/id"},
        \\    {"op":"reference-exists","path":"/items","reference":"/related_ids","target":"/items","key":"/id","self_reference":"reject"},
        \\    {"op":"reference-exists","path":"/selected","reference":"","target":"/containers","target_items":"/entries","target_rules":[{"op":"enum","path":"/status","values":["active"]}],"key":"/id","coverage":"all-targets"},
        \\    {"op":"path-format","path":"/groups","items":"/members","target":"/label","fragments":[{"parent":"/prefix"},{"literal":":"},{"item":"/name"}]},
        \\    {"op":"optional-field","path":"/meta/closure","rules":[{"op":"enum","values":["confirmed"]}]},
        \\    {"op":"all","path":"/items","rules":[
        \\      {"op":"exact-object","keys":["id","labels","related_ids"]},
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
        \\    {"op":"reference-exists","path":"/accepted","reference":"","target":"/universe","key":""},
        \\    {"op":"reference-exists","path":"/ordering","reference":"","target":"/universe","key":"","coverage":"all-targets"},
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
        "{\"schema\":\"example/v1\",\"record_id\":\"record-1\",\"status\":\"open\",\"tags\":[\"a\",\"b\"],\"mirror\":\"open\",\"items\":[{\"id\":\"item-1\",\"labels\":[\"a\"],\"related_ids\":[\"item-2\"]},{\"id\":\"item-2\",\"labels\":[\"b\"],\"related_ids\":[]}],\"groups\":[{\"prefix\":\"g\",\"members\":[{\"name\":\"one\",\"label\":\"g:one\"}]}],\"links\":[{\"item_refs\":[\"item-1\",\"item-2\"],\"optional_target\":null,\"expected\":[\"a\"],\"prohibited\":[\"b\"]}],\"optional_links\":[{}],\"containers\":[{\"entries\":[{\"id\":\"nested-1\",\"status\":\"active\"},{\"id\":\"nested-2\",\"status\":\"inactive\"}]}],\"selected\":[\"nested-1\"],\"meta\":{},\"universe\":[\"a\",\"b\"],\"ordering\":[\"a\",\"b\"],\"accepted\":[\"a\"],\"rejected\":[\"b\"],\"targets\":[\"x\",\"y\"],\"mappings\":[{\"from\":\"a\",\"to\":\"x\"},{\"from\":\"b\",\"to\":\"y\"}]}";
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

    const present_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"meta\":{}",
        "\"meta\":{\"closure\":\"confirmed\"}",
    );
    defer std.testing.allocator.free(present_bytes);
    var valid_present = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = present_bytes,
        }},
    );
    defer valid_present.deinit(std.testing.allocator);
    try std.testing.expect(valid_present.valid);

    const invalid_optional_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"meta\":{}",
        "\"meta\":{\"closure\":\"wrong\"}",
    );
    defer std.testing.allocator.free(invalid_optional_bytes);
    var invalid_optional = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = invalid_optional_bytes,
        }},
    );
    defer invalid_optional.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_optional.valid);

    const invalid_scalar_reference_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"accepted\":[\"a\"]",
        "\"accepted\":[\"missing\"]",
    );
    defer std.testing.allocator.free(invalid_scalar_reference_bytes);
    var invalid_scalar_reference = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = invalid_scalar_reference_bytes,
        }},
    );
    defer invalid_scalar_reference.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_scalar_reference.valid);

    const incomplete_coverage_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"ordering\":[\"a\",\"b\"]",
        "\"ordering\":[\"a\"]",
    );
    defer std.testing.allocator.free(incomplete_coverage_bytes);
    var incomplete_coverage = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = incomplete_coverage_bytes,
        }},
    );
    defer incomplete_coverage.deinit(std.testing.allocator);
    try std.testing.expect(!incomplete_coverage.valid);

    const self_reference_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"related_ids\":[\"item-2\"]",
        "\"related_ids\":[\"item-1\"]",
    );
    defer std.testing.allocator.free(self_reference_bytes);
    var self_reference = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = self_reference_bytes,
        }},
    );
    defer self_reference.deinit(std.testing.allocator);
    try std.testing.expect(!self_reference.valid);

    const filtered_reference_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"selected\":[\"nested-1\"]",
        "\"selected\":[\"nested-2\"]",
    );
    defer std.testing.allocator.free(filtered_reference_bytes);
    var filtered_reference = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = filtered_reference_bytes,
        }},
    );
    defer filtered_reference.deinit(std.testing.allocator);
    try std.testing.expect(!filtered_reference.valid);

    const invalid_format_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"label\":\"g:one\"",
        "\"label\":\"wrong\"",
    );
    defer std.testing.allocator.free(invalid_format_bytes);
    var invalid_format = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = invalid_format_bytes,
        }},
    );
    defer invalid_format.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_format.valid);

    var invalid = try validate(
        std.testing.allocator,
        &definition_plan,
        &plan,
        &.{.{
            .name = "record",
            .bytes = "{\"schema\":\"example/v1\",\"record_id\":\"bad id\",\"status\":\"closed\",\"tags\":[\"b\",\"a\",\"a\"],\"mirror\":\"open\",\"items\":[{\"id\":\"item-1\",\"labels\":[1,\"forbidden\"],\"related_ids\":[]},{\"id\":\"item-1\",\"labels\":[],\"related_ids\":[]}],\"groups\":[{\"prefix\":\"g\",\"members\":[{\"name\":\"one\",\"label\":\"g:one\"}]}],\"links\":[{\"item_refs\":[\"missing\"],\"optional_target\":null,\"expected\":[\"same\"],\"prohibited\":[\"same\"]}],\"optional_links\":[{}],\"containers\":[{\"entries\":[{\"id\":\"nested-1\",\"status\":\"active\"}]}],\"selected\":[\"nested-1\"],\"meta\":{},\"universe\":[\"a\",\"b\"],\"ordering\":[\"a\",\"b\"],\"accepted\":[\"a\",\"b\"],\"rejected\":[\"b\"],\"targets\":[\"x\",\"y\"],\"mappings\":[{\"from\":\"a\",\"to\":\"x\"},{\"from\":\"a\",\"to\":\"y\"}],\"extra\":true}",
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

test "compiled identifier and repository path policies preserve exact boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/path-policy","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["all","bounded-string","digest","enum","exact-object","one-of","safe-identifier","safe-relative-path"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","path":"","keys":["goal_id","identity","label","paths"]},{"op":"safe-identifier","path":"/goal_id","max":128,"style":"lowercase-component"},{"op":"bounded-string","path":"/label","trimmed_min":1,"max":128},{"op":"one-of","path":"/identity","rules":[{"op":"enum","values":[null]},{"op":"digest"}]},{"op":"all","path":"/paths","rules":[{"op":"safe-relative-path","allow_root":true,"reserved_roots":[".git",".ledger"],"case_insensitive_reserved":true}]}]},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":16,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
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
        4096,
    );
    defer encoder.deinit();
    try encodeCache(&plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(std.testing.allocator, &decoder);
    defer cached.deinit(std.testing.allocator);
    try decoder.finish();
    try validateCachePlan(&cached, &definition_plan);
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

    var valid = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = "{\"goal_id\":\"goal-1\",\"identity\":null,\"label\":\"value\",\"paths\":[\".\",\".github\",\"src/lib\"]}",
        }},
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(valid.valid);

    var valid_digest = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = "{\"goal_id\":\"goal-1\",\"identity\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"label\":\"value\",\"paths\":[\"src\"]}",
        }},
    );
    defer valid_digest.deinit(std.testing.allocator);
    try std.testing.expect(valid_digest.valid);

    const invalid_cases = [_][]const u8{
        "{\"goal_id\":\"Goal-1\",\"identity\":null,\"label\":\"value\",\"paths\":[\"src\"]}",
        "{\"goal_id\":\".goal\",\"identity\":null,\"label\":\"value\",\"paths\":[\"src\"]}",
        "{\"goal_id\":\"goal-1\",\"identity\":null,\"label\":\"value\",\"paths\":[\".GIT/config\"]}",
        "{\"goal_id\":\"goal-1\",\"identity\":null,\"label\":\"value\",\"paths\":[\".ledger\"]}",
        "{\"goal_id\":\"goal-1\",\"identity\":null,\"label\":\"value\",\"paths\":[\"src/../lib\"]}",
        "{\"goal_id\":\"goal-1\",\"identity\":\"not-a-digest\",\"label\":\"value\",\"paths\":[\"src\"]}",
        "{\"goal_id\":\"goal-1\",\"identity\":null,\"label\":\" \\t\",\"paths\":[\"src\"]}",
    };
    for (invalid_cases) |bytes| {
        var rejected = try validate(
            std.testing.allocator,
            &definition_plan,
            &cached,
            &.{.{ .name = "record", .bytes = bytes }},
        );
        defer rejected.deinit(std.testing.allocator);
        try std.testing.expect(!rejected.valid);
    }
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

test "definition references compile imported validators and survive cache round trips" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "receipt.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/receipt","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["bounded-string","exact-object","enum","scalar-type","tagged-union"]},"inputs":{"receipt":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","path":"","keys":["count","parent","status"]},{"op":"scalar-type","path":"/count","type":"integer"},{"op":"enum","path":"/status","values":["complete"]},{"op":"tagged-union","path":"/parent","variants":[{"kind":"null","rules":[]},{"kind":"object","rules":[{"op":"exact-object","keys":["value"]},{"op":"bounded-string","path":"/value","trimmed_min":1,"max":128}]}]}]},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":1024,"max_records":4,"max_output_bytes":1024,"max_diagnostics":8,"max_reducer_states":1}}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packet.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/packet","owner":"example","imports":[{"id":"example/receipt","path":"receipt.json"}],"requires":{"abi":"ledger-artifact-abi/v1","operators":["definition-ref","exact-object"]},"inputs":{"packet":{"codec":"json","max_bytes":2048}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","path":"","required_keys":["receipt"],"optional_keys":["metadata"]},{"op":"definition-ref","path":"/receipt","definition":"example/receipt"}]},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":2048,"max_store_bytes":2048,"max_records":4,"max_output_bytes":2048,"max_diagnostics":8,"max_reducer_states":1}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "packet.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "packet.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), definition_plan.imports.len);
    try std.testing.expectEqualStrings(
        "example/receipt",
        definition_plan.imports[0].id,
    );

    var definition_encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        8 * 1024 * 1024,
    );
    defer definition_encoder.deinit();
    try definition.encodeCache(&definition_plan, &definition_encoder);
    const definition_payload = try definition_encoder.toOwnedSlice();
    defer std.testing.allocator.free(definition_payload);
    var definition_decoder =
        definition_core.cache.Decoder.init(definition_payload);
    var cached_definition = try definition.decodeCache(
        std.testing.allocator,
        &definition_decoder,
    );
    defer cached_definition.deinit(std.testing.allocator);
    try definition_decoder.finish();
    try std.testing.expectEqual(
        @as(usize, 1),
        cached_definition.imports.len,
    );

    var plan = try compile(std.testing.allocator, &cached_definition);
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
    try validateCachePlan(&cached, &cached_definition);

    var valid = try validate(
        std.testing.allocator,
        &cached_definition,
        &cached,
        &.{.{
            .name = "packet",
            .bytes = "{\"receipt\":{\"count\":2,\"parent\":null,\"status\":\"complete\"}}",
        }},
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(valid.valid);

    var valid_with_optional = try validate(
        std.testing.allocator,
        &cached_definition,
        &cached,
        &.{.{
            .name = "packet",
            .bytes = "{\"metadata\":{},\"receipt\":{\"count\":2,\"parent\":{\"value\":\"prior\"},\"status\":\"complete\"}}",
        }},
    );
    defer valid_with_optional.deinit(std.testing.allocator);
    try std.testing.expect(valid_with_optional.valid);

    var invalid = try validate(
        std.testing.allocator,
        &cached_definition,
        &cached,
        &.{.{
            .name = "packet",
            .bytes = "{\"receipt\":{\"count\":\"two\",\"parent\":null,\"status\":\"complete\"}}",
        }},
    );
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expect(!invalid.valid);

    var unknown_key = try validate(
        std.testing.allocator,
        &cached_definition,
        &cached,
        &.{.{
            .name = "packet",
            .bytes = "{\"other\":{},\"receipt\":{\"count\":2,\"parent\":null,\"status\":\"complete\"}}",
        }},
    );
    defer unknown_key.deinit(std.testing.allocator);
    try std.testing.expect(!unknown_key.valid);

    var invalid_variant = try validate(
        std.testing.allocator,
        &cached_definition,
        &cached,
        &.{.{
            .name = "packet",
            .bytes = "{\"receipt\":{\"count\":2,\"parent\":{\"value\":\"\"},\"status\":\"complete\"}}",
        }},
    );
    defer invalid_variant.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_variant.valid);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileForAllocationFailure,
        .{&cached_definition},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeForAllocationFailure,
        .{payload},
    );
}
