const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");

const max_regex_subject_bytes: usize = 16 * 1024 * 1024;
const max_sha256_subject_bytes: usize = 16 * 1024 * 1024;

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
    value,

    fn deinit(self: *CompiledFormatPart, allocator: std.mem.Allocator) void {
        if (self.* == .literal) allocator.free(self.literal);
        self.* = undefined;
    }
};

const RegexQuantifier = enum {
    one,
    zero_or_one,
    zero_or_more,
    one_or_more,
};

const CompiledRegexAtom = struct {
    bytes: [4]u64,
    quantifier: RegexQuantifier,
};

const CompiledRegexPattern = struct {
    atoms: []CompiledRegexAtom,

    fn deinit(
        self: *CompiledRegexPattern,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.atoms);
        self.* = undefined;
    }
};

const Sha256Mode = enum {
    canonical_json_null,
    framed_items,
    framed_fields,
};

const CompiledReferenceTarget = struct {
    pointer_id: u16,
    optional: bool = false,
    items_pointer_id: ?u16 = null,
    key_pointer_id: ?u16 = null,
    coverage_key_pointer_id: ?u16 = null,
    rules: []CompiledRule,
    match_rules: []CompiledRule,
    coverage_rules: []CompiledRule,
    format_parts: []CompiledFormatPart,

    fn deinit(
        self: *CompiledReferenceTarget,
        allocator: std.mem.Allocator,
    ) void {
        for (self.rules) |*rule| rule.deinit(allocator);
        allocator.free(self.rules);
        for (self.match_rules) |*rule| rule.deinit(allocator);
        allocator.free(self.match_rules);
        for (self.coverage_rules) |*rule| rule.deinit(allocator);
        allocator.free(self.coverage_rules);
        for (self.format_parts) |*part| part.deinit(allocator);
        allocator.free(self.format_parts);
        self.* = undefined;
    }
};

const CompiledReferenceSource = struct {
    pointer_id: u16,
    items_pointer_id: ?u16 = null,
    reference_pointer_id: u16,
    optional: bool = false,
    rules: []CompiledRule,
    format_parts: []CompiledFormatPart,

    fn deinit(
        self: *CompiledReferenceSource,
        allocator: std.mem.Allocator,
    ) void {
        for (self.rules) |*rule| rule.deinit(allocator);
        allocator.free(self.rules);
        for (self.format_parts) |*part| part.deinit(allocator);
        allocator.free(self.format_parts);
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
    allow_additional: bool = false,
    allow_null: bool = false,
    total_coverage: bool = false,
    reject_self_reference: bool = false,
    ignore_null_references: bool = false,
    then_nonempty: bool = false,
    children: []CompiledRule,
    coverage_children: []CompiledRule,
    variants: []CompiledVariant,
    format_parts: []CompiledFormatPart,
    regex_patterns: []CompiledRegexPattern,
    sha256_mode: ?Sha256Mode = null,
    sha256_prefix: ?[]u8 = null,
    reference_sources: []CompiledReferenceSource,
    reference_targets: []CompiledReferenceTarget,

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
        for (self.coverage_children) |*child| child.deinit(allocator);
        allocator.free(self.coverage_children);
        for (self.variants) |*variant| variant.deinit(allocator);
        allocator.free(self.variants);
        for (self.format_parts) |*part| part.deinit(allocator);
        allocator.free(self.format_parts);
        for (self.regex_patterns) |*pattern| pattern.deinit(allocator);
        allocator.free(self.regex_patterns);
        if (self.sha256_prefix) |prefix| allocator.free(prefix);
        for (self.reference_sources) |*source| source.deinit(allocator);
        allocator.free(self.reference_sources);
        for (self.reference_targets) |*target| target.deinit(allocator);
        allocator.free(self.reference_targets);
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
    inputs: []const definition.Input,
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
        for (self.inputs, 0..) |input, index| {
            if (std.mem.eql(u8, input.name, name)) return @intCast(index);
        }
        return error.UnknownRuleInput;
    }

    fn compileRawRule(self: *Builder, value: std.json.Value) !void {
        const object = try definition_core.json.object(value);
        const operator = try definition.Operator.parse(
            try definition_core.json.requiredString(object, "op"),
        );
        if (!isValidationOperator(operator)) {
            return error.UnsupportedValidationOperator;
        }
        if (!self.definition_plan.requires(operator)) {
            return error.UndeclaredArtifactOperator;
        }
        const pointer_id = if (object.get("path")) |raw_path|
            try self.internPointer(try definition_core.json.string(raw_path))
        else
            null;
        const import_index = if (operator == .definition_ref)
            try findImportedDefinition(
                self.definition_plan,
                try definition_core.json.requiredString(
                    object,
                    "definition",
                ),
            )
        else
            null;
        const canonical_config =
            try definition_core.canonical_json.canonicalJsonAlloc(
                self.allocator,
                value,
            );
        defer self.allocator.free(canonical_config);
        try self.compileRule(.{
            .operator = operator,
            .pointer_id = pointer_id,
            .import_index = import_index,
            .canonical_config = canonical_config,
        });
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
        else if (self.inputs.len == 1)
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
            .coverage_children = try self.allocator.alloc(CompiledRule, 0),
            .variants = try self.allocator.alloc(CompiledVariant, 0),
            .format_parts = try self.allocator.alloc(CompiledFormatPart, 0),
            .regex_patterns = try self.allocator.alloc(
                CompiledRegexPattern,
                0,
            ),
            .reference_sources = try self.allocator.alloc(
                CompiledReferenceSource,
                0,
            ),
            .reference_targets = try self.allocator.alloc(
                CompiledReferenceTarget,
                0,
            ),
        };
        errdefer rule.deinit(self.allocator);

        switch (source.operator) {
            .exact_object => try compileExactObjectRule(
                self.allocator,
                object,
                true,
                &rule,
            ),
            .field_absent => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "path" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "path" },
                );
            },
            .optional_field => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "path", "rules", "allow_null" },
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
                rule.allow_null =
                    try optionalBoolean(object, "allow_null") orelse false;
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
            .regex => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "path", "patterns", "max" },
                );
                rule.max_count = try optionalUnsigned(object, "max") orelse
                    return error.MissingRegexBound;
                if (rule.max_count.? == 0 or
                    rule.max_count.? > max_regex_subject_bytes)
                {
                    return error.InvalidRegexBound;
                }
                rule.regex_patterns = try compileRegexPatterns(
                    self.allocator,
                    try definition_core.json.field(object, "patterns"),
                );
            },
            .sha256 => try self.compileSha256Rule(object, true, &rule),
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
            .sorted => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "path", "key" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "op", "path" },
                );
                if (object.get("key")) |raw_key| {
                    rule.other_pointer_id = try self.internPointer(
                        try definition_core.json.string(raw_key),
                    );
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
            .path_scope_subset,
            .path_scope_disjoint,
            .member_of,
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
            .declared_field_values => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{
                        "op",
                        "input",
                        "path",
                        "object",
                        "declarations",
                        "declaration_paths",
                        "type",
                        "min",
                        "max",
                    },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{
                        "op",
                        "path",
                        "object",
                        "declarations",
                        "declaration_paths",
                        "type",
                    },
                );
                if (source.pointer_id == null) {
                    return error.DeclaredFieldCollectionMissing;
                }
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "object"),
                );
                const declaration_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(
                        object,
                        "declarations",
                    ),
                );
                const declaration_paths = try self.parsePaths(
                    try definition_core.json.field(
                        object,
                        "declaration_paths",
                    ),
                );
                defer self.allocator.free(declaration_paths);
                rule.path_ids = try self.allocator.alloc(
                    u16,
                    declaration_paths.len + 1,
                );
                rule.path_ids[0] = declaration_pointer_id;
                @memcpy(rule.path_ids[1..], declaration_paths);
                rule.scalar_kind = try JsonKind.parse(
                    try definition_core.json.requiredString(object, "type"),
                );
                if (rule.scalar_kind.? != .integer and
                    rule.scalar_kind.? != .number)
                {
                    return error.DeclaredFieldValueTypeUnsupported;
                }
                rule.min_number = try optionalNumber(object, "min");
                rule.max_number = try optionalNumber(object, "max");
                if (rule.min_number == null and rule.max_number == null) {
                    return error.MissingRuleBound;
                }
                if (rule.min_number != null and
                    rule.max_number != null and
                    rule.min_number.? > rule.max_number.?)
                {
                    return error.InvalidRuleBounds;
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
                    try definition_core.json.string(
                        try definition_core.json.field(object, "left"),
                    ),
                );
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.string(
                        try definition_core.json.field(object, "right"),
                    ),
                );
            },
            .implies => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{
                        "op",
                        "input",
                        "if",
                        "equals",
                        "nonempty",
                        "then",
                        "then_input",
                        "then_equals",
                        "then_nonempty",
                    },
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
                rule.other_input_index = if (object.get("then_input")) |raw|
                    try self.inputIndex(
                        try definition_core.json.string(raw),
                    )
                else
                    input_index;
                const condition_equals = object.get("equals");
                const condition_nonempty =
                    try optionalBoolean(object, "nonempty") orelse false;
                const consequent_equals = object.get("then_equals");
                rule.then_nonempty =
                    try optionalBoolean(object, "then_nonempty") orelse false;
                if (condition_nonempty and condition_equals != null) {
                    return error.ConflictingImplicationPredicates;
                }
                if (consequent_equals != null and rule.then_nonempty) {
                    return error.ConflictingImplicationConsequences;
                }
                if (consequent_equals != null and
                    condition_equals == null and !condition_nonempty)
                {
                    return error.ImplicationConsequenceRequiresPredicate;
                }
                const value_count: usize =
                    @as(usize, @intFromBool(condition_equals != null)) +
                    @as(usize, @intFromBool(consequent_equals != null));
                if (value_count != 0) {
                    const values = try self.allocator.alloc(
                        EnumScalar,
                        value_count,
                    );
                    var value_index: usize = 0;
                    errdefer {
                        for (values[0..value_index]) |*value| {
                            value.deinit(self.allocator);
                        }
                        self.allocator.free(values);
                    }
                    if (condition_equals) |value| {
                        values[value_index] = try parseEnumScalar(
                            self.allocator,
                            value,
                        );
                        value_index += 1;
                    }
                    if (consequent_equals) |value| {
                        values[value_index] = try parseEnumScalar(
                            self.allocator,
                            value,
                        );
                        value_index += 1;
                    }
                    rule.values = values;
                }
                if (condition_nonempty) {
                    if (condition_equals != null) {
                        return error.ConflictingImplicationPredicates;
                    }
                    rule.min_count = 1;
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
            .exactly_one, .at_least_one => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "input", "path", "paths", "rules" },
                );
                const has_path = object.get("path") != null;
                const has_paths = object.get("paths") != null;
                if (has_path == has_paths) {
                    return error.ConflictingCountRuleTargets;
                }
                if (has_path) {
                    if (source.pointer_id == null) {
                        return error.CountRuleCollectionMissing;
                    }
                    rule.children = try self.compileItemRules(
                        try definition_core.json.field(object, "rules"),
                        input_index,
                        0,
                    );
                } else {
                    if (object.get("rules") != null) {
                        return error.CountRuleRulesUnexpected;
                    }
                    rule.path_ids = try self.parsePaths(
                        try definition_core.json.field(object, "paths"),
                    );
                }
            },
            .keyed_join => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{
                        "op",
                        "input",
                        "collection",
                        "key",
                        "selector",
                        "value",
                        "equals",
                        "rules",
                    },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{
                        "op",
                        "collection",
                        "key",
                        "selector",
                        "value",
                        "equals",
                    },
                );
                rule.pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(
                        object,
                        "collection",
                    ),
                );
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "equals"),
                );
                rule.path_ids = try self.allocator.alloc(u16, 3);
                rule.path_ids[0] = try self.internPointer(
                    try definition_core.json.requiredString(object, "key"),
                );
                rule.path_ids[1] = try self.internPointer(
                    try definition_core.json.requiredString(
                        object,
                        "selector",
                    ),
                );
                rule.path_ids[2] = try self.internPointer(
                    try definition_core.json.requiredString(object, "value"),
                );
                if (object.get("rules")) |raw_rules| {
                    rule.children = try self.compileItemRules(
                        raw_rules,
                        input_index,
                        0,
                    );
                }
            },
            .predecessor_successor => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{
                        "op",
                        "input",
                        "predecessor",
                        "predecessor_key",
                        "successor",
                        "successor_key",
                        "preserved",
                        "retired",
                        "introduced",
                        "mappings",
                        "mapping_predecessors",
                        "mapping_successors",
                    },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{
                        "op",
                        "predecessor",
                        "predecessor_key",
                        "successor",
                        "successor_key",
                        "preserved",
                        "retired",
                        "introduced",
                        "mappings",
                        "mapping_predecessors",
                        "mapping_successors",
                    },
                );
                rule.pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(
                        object,
                        "predecessor",
                    ),
                );
                rule.other_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(
                        object,
                        "successor",
                    ),
                );
                const pointer_names = [_][]const u8{
                    "predecessor_key",
                    "successor_key",
                    "preserved",
                    "retired",
                    "introduced",
                    "mappings",
                    "mapping_predecessors",
                    "mapping_successors",
                };
                rule.path_ids = try self.allocator.alloc(
                    u16,
                    pointer_names.len,
                );
                for (pointer_names, 0..) |name, index| {
                    rule.path_ids[index] = try self.internPointer(
                        try definition_core.json.requiredString(object, name),
                    );
                }
            },
            .one_of, .all_rules, .any_rules, .no_rules, .object_values => {
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
                        !isValidationOperator(imported_rule.operator))
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
                    &.{ "op", "input", "path", "key", "sources" },
                );
                const has_path = object.get("path") != null;
                const has_sources = object.get("sources") != null;
                if (has_path == has_sources) {
                    return error.ConflictingKeyedUniqueSources;
                }
                if (has_path) {
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
                } else {
                    if (object.get("key") != null) {
                        return error.KeyedUniqueKeyUnexpected;
                    }
                    rule.pointer_id = null;
                    rule.reference_sources = try self.compileKeySources(
                        try definition_core.json.field(object, "sources"),
                    );
                }
            },
            .reference_exists => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{
                        "op",
                        "input",
                        "path",
                        "reference",
                        "sources",
                        "target_input",
                        "target",
                        "target_items",
                        "target_rules",
                        "coverage_rules",
                        "targets",
                        "key",
                        "coverage",
                        "self_reference",
                        "ignore_null",
                    },
                );
                try definition_core.json.requireFields(object, &.{"op"});
                rule.other_input_index = if (object.get("target_input")) |raw|
                    try self.inputIndex(try definition_core.json.string(raw))
                else
                    input_index;
                if (object.get("sources")) |raw_sources| {
                    if (object.get("path") != null or
                        object.get("reference") != null)
                    {
                        return error.ConflictingReferenceSources;
                    }
                    rule.reference_sources =
                        try self.compileReferenceSources(
                            raw_sources,
                            input_index,
                        );
                } else {
                    try definition_core.json.requireFields(
                        object,
                        &.{ "path", "reference" },
                    );
                    if (source.pointer_id == null) {
                        return error.ReferenceCollectionMissing;
                    }
                    rule.other_pointer_id = try self.internPointer(
                        try definition_core.json.string(
                            try definition_core.json.field(
                                object,
                                "reference",
                            ),
                        ),
                    );
                }
                if (object.get("targets")) |raw_targets| {
                    if (object.get("target") != null or
                        object.get("target_items") != null or
                        object.get("target_rules") != null or
                        object.get("coverage_rules") != null or
                        object.get("key") != null)
                    {
                        return error.ConflictingReferenceTargets;
                    }
                    rule.reference_targets =
                        try self.compileReferenceTargets(
                            raw_targets,
                            rule.other_input_index.?,
                        );
                } else {
                    try definition_core.json.requireFields(
                        object,
                        &.{ "target", "key" },
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
                        try definition_core.json.requiredString(
                            object,
                            "target",
                        ),
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
                    if (object.get("coverage_rules")) |raw_rules| {
                        rule.coverage_children = try self.compileItemRules(
                            raw_rules,
                            rule.other_input_index.?,
                            0,
                        );
                    }
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
                    if (rule.reference_sources.len != 0 or
                        rule.reference_targets.len != 0 or
                        rule.other_input_index.? != rule.input_index or
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

    fn compileReferenceSources(
        self: *Builder,
        raw: std.json.Value,
        input_index: u8,
    ) anyerror![]CompiledReferenceSource {
        const items = try definition_core.json.array(raw);
        if (items.items.len == 0 or items.items.len > 64) {
            return error.ReferenceSourceCountInvalid;
        }
        const sources = try self.allocator.alloc(
            CompiledReferenceSource,
            items.items.len,
        );
        var initialized: usize = 0;
        errdefer {
            for (sources[0..initialized]) |*source| {
                source.deinit(self.allocator);
            }
            self.allocator.free(sources);
        }
        for (items.items, 0..) |item, index| {
            const object = try definition_core.json.object(item);
            try definition_core.json.requireExactKeys(
                object,
                &.{
                    "path",
                    "items",
                    "reference",
                    "fragments",
                    "rules",
                    "optional",
                },
            );
            try definition_core.json.requireFields(
                object,
                &.{ "path", "reference" },
            );
            var source: CompiledReferenceSource = .{
                .pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "path"),
                ),
                .items_pointer_id = if (object.get("items")) |raw_items|
                    try self.internPointer(
                        try definition_core.json.string(raw_items),
                    )
                else
                    null,
                .reference_pointer_id = try self.internPointer(
                    try definition_core.json.string(
                        try definition_core.json.field(
                            object,
                            "reference",
                        ),
                    ),
                ),
                .optional = try optionalBoolean(object, "optional") orelse false,
                .rules = try self.allocator.alloc(CompiledRule, 0),
                .format_parts = try self.allocator.alloc(
                    CompiledFormatPart,
                    0,
                ),
            };
            errdefer source.deinit(self.allocator);
            if (object.get("rules")) |raw_rules| {
                source.rules = try self.compileItemRules(
                    raw_rules,
                    input_index,
                    0,
                );
            }
            if (object.get("fragments")) |raw_fragments| {
                source.format_parts = try self.compileFormatParts(
                    raw_fragments,
                    true,
                );
            }
            sources[index] = source;
            initialized += 1;
        }
        return sources;
    }

    fn compileKeySources(
        self: *Builder,
        raw: std.json.Value,
    ) anyerror![]CompiledReferenceSource {
        const items = try definition_core.json.array(raw);
        if (items.items.len < 2 or items.items.len > 64) {
            return error.KeyedUniqueSourceCountInvalid;
        }
        const sources = try self.allocator.alloc(
            CompiledReferenceSource,
            items.items.len,
        );
        var initialized: usize = 0;
        errdefer {
            for (sources[0..initialized]) |*source| {
                source.deinit(self.allocator);
            }
            self.allocator.free(sources);
        }
        for (items.items, 0..) |item, index| {
            const object = try definition_core.json.object(item);
            try definition_core.json.requireExactKeys(
                object,
                &.{ "path", "key" },
            );
            try definition_core.json.requireFields(
                object,
                &.{ "path", "key" },
            );
            sources[index] = .{
                .pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "path"),
                ),
                .reference_pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "key"),
                ),
                .rules = try self.allocator.alloc(CompiledRule, 0),
                .format_parts = try self.allocator.alloc(
                    CompiledFormatPart,
                    0,
                ),
            };
            initialized += 1;
        }
        return sources;
    }

    fn compileReferenceTargets(
        self: *Builder,
        raw: std.json.Value,
        input_index: u8,
    ) anyerror![]CompiledReferenceTarget {
        const items = try definition_core.json.array(raw);
        if (items.items.len == 0 or items.items.len > 64) {
            return error.ReferenceTargetCountInvalid;
        }
        const targets = try self.allocator.alloc(
            CompiledReferenceTarget,
            items.items.len,
        );
        var initialized: usize = 0;
        errdefer {
            for (targets[0..initialized]) |*target| {
                target.deinit(self.allocator);
            }
            self.allocator.free(targets);
        }
        for (items.items, 0..) |item, index| {
            const object = try definition_core.json.object(item);
            try definition_core.json.requireExactKeys(
                object,
                &.{
                    "path",
                    "items",
                    "key",
                    "coverage_key",
                    "fragments",
                    "rules",
                    "match_rules",
                    "coverage_rules",
                    "optional",
                },
            );
            try definition_core.json.requireFields(object, &.{"path"});
            const has_key = object.get("key") != null;
            const has_fragments = object.get("fragments") != null;
            if (has_key == has_fragments) {
                return error.ReferenceTargetKeyInvalid;
            }
            var target: CompiledReferenceTarget = .{
                .pointer_id = try self.internPointer(
                    try definition_core.json.requiredString(object, "path"),
                ),
                .optional = try optionalBoolean(object, "optional") orelse false,
                .items_pointer_id = if (object.get("items")) |raw_items|
                    try self.internPointer(
                        try definition_core.json.string(raw_items),
                    )
                else
                    null,
                .key_pointer_id = if (object.get("key")) |raw_key|
                    try self.internPointer(
                        try definition_core.json.string(raw_key),
                    )
                else
                    null,
                .coverage_key_pointer_id = if (object.get(
                    "coverage_key",
                )) |raw_key|
                    try self.internPointer(
                        try definition_core.json.string(raw_key),
                    )
                else
                    null,
                .rules = try self.allocator.alloc(CompiledRule, 0),
                .match_rules = try self.allocator.alloc(CompiledRule, 0),
                .coverage_rules = try self.allocator.alloc(CompiledRule, 0),
                .format_parts = try self.allocator.alloc(
                    CompiledFormatPart,
                    0,
                ),
            };
            errdefer target.deinit(self.allocator);
            if (object.get("rules")) |raw_rules| {
                target.rules = try self.compileItemRules(
                    raw_rules,
                    input_index,
                    0,
                );
            }
            if (object.get("match_rules")) |raw_rules| {
                target.match_rules = try self.compileItemRules(
                    raw_rules,
                    input_index,
                    0,
                );
            }
            if (object.get("coverage_rules")) |raw_rules| {
                target.coverage_rules = try self.compileItemRules(
                    raw_rules,
                    input_index,
                    0,
                );
            }
            if (object.get("fragments")) |raw_fragments| {
                target.format_parts = try self.compileFormatParts(
                    raw_fragments,
                    false,
                );
            }
            targets[index] = target;
            initialized += 1;
        }
        return targets;
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
        rule.format_parts = try self.compileFormatParts(
            try definition_core.json.field(object, "fragments"),
            false,
        );
    }

    fn compileFormatParts(
        self: *Builder,
        raw: std.json.Value,
        allow_value: bool,
    ) anyerror![]CompiledFormatPart {
        const raw_fragments = try definition_core.json.array(raw);
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
            } else if (fragment.get("value")) |raw_value| {
                if (!allow_value or
                    !try definition_core.json.boolean(raw_value))
                {
                    return error.PathFormatFragmentInvalid;
                }
                parts[index] = .value;
            } else {
                return error.PathFormatFragmentInvalid;
            }
            initialized += 1;
        }
        return parts;
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
            .coverage_children = try self.allocator.alloc(CompiledRule, 0),
            .variants = try self.allocator.alloc(CompiledVariant, 0),
            .format_parts = try self.allocator.alloc(CompiledFormatPart, 0),
            .regex_patterns = try self.allocator.alloc(
                CompiledRegexPattern,
                0,
            ),
            .reference_sources = try self.allocator.alloc(
                CompiledReferenceSource,
                0,
            ),
            .reference_targets = try self.allocator.alloc(
                CompiledReferenceTarget,
                0,
            ),
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
                    &.{ "op", "path", "rules", "allow_null" },
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
                rule.allow_null =
                    try optionalBoolean(object, "allow_null") orelse false;
            },
            .required_field,
            .field_absent,
            .digest,
            .timestamp,
            .unique,
            => try definition_core.json.requireExactKeys(
                object,
                &.{ "op", "path" },
            ),
            .sorted => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "key" },
                );
                if (object.get("key")) |raw_key| {
                    rule.other_pointer_id = try self.internPointer(
                        try definition_core.json.string(raw_key),
                    );
                }
            },
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
            .regex => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path", "patterns", "max" },
                );
                rule.max_count = try optionalUnsigned(object, "max") orelse
                    return error.MissingRegexBound;
                if (rule.max_count.? == 0 or
                    rule.max_count.? > max_regex_subject_bytes)
                {
                    return error.InvalidRegexBound;
                }
                rule.regex_patterns = try compileRegexPatterns(
                    self.allocator,
                    try definition_core.json.field(object, "patterns"),
                );
            },
            .sha256 => try self.compileSha256Rule(object, false, &rule),
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
            .path_scope_subset,
            .path_scope_disjoint,
            .member_of,
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
                    &.{ "op", "path", "paths", "rules" },
                );
                const has_path = object.get("path") != null;
                const has_paths = object.get("paths") != null;
                if (has_path == has_paths) {
                    return error.ConflictingCountRuleTargets;
                }
                if (has_path) {
                    if (pointer_id == null) {
                        return error.CountRuleCollectionMissing;
                    }
                    rule.children = try self.compileItemRules(
                        try definition_core.json.field(object, "rules"),
                        input_index,
                        depth + 1,
                    );
                } else {
                    if (object.get("rules") != null) {
                        return error.CountRuleRulesUnexpected;
                    }
                    rule.path_ids = try self.parsePaths(
                        try definition_core.json.field(object, "paths"),
                    );
                }
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
            .reference_exists => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{
                        "op",
                        "path",
                        "reference",
                        "target",
                        "target_items",
                        "target_rules",
                        "coverage_rules",
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
                if (pointer_id == null) {
                    return error.ReferenceCollectionMissing;
                }
                rule.other_input_index = input_index;
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
                if (target_items) |target_items_pointer_id| {
                    rule.path_ids[2] = target_items_pointer_id;
                }
                if (object.get("target_rules")) |raw_rules| {
                    rule.children = try self.compileItemRules(
                        raw_rules,
                        input_index,
                        depth + 1,
                    );
                }
                if (object.get("coverage_rules")) |raw_rules| {
                    rule.coverage_children = try self.compileItemRules(
                        raw_rules,
                        input_index,
                        depth + 1,
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
                    if (rule.path_ids[0] != pointer_id) {
                        return error.SelfReferenceRequiresOneCollection;
                    }
                    rule.reject_self_reference = true;
                }
                rule.ignore_null_references =
                    try optionalBoolean(object, "ignore_null") orelse false;
            },
            .implies => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{
                        "op",
                        "if",
                        "equals",
                        "nonempty",
                        "then",
                        "then_nonempty",
                    },
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
                rule.other_input_index = input_index;
                if (object.get("equals")) |value| {
                    const values = try self.allocator.alloc(EnumScalar, 1);
                    errdefer self.allocator.free(values);
                    values[0] = try parseEnumScalar(self.allocator, value);
                    rule.values = values;
                }
                if (try optionalBoolean(object, "nonempty") orelse false) {
                    if (rule.values.len != 0) {
                        return error.ConflictingImplicationPredicates;
                    }
                    rule.min_count = 1;
                }
                rule.then_nonempty =
                    try optionalBoolean(object, "then_nonempty") orelse false;
            },
            .one_of, .all_rules, .any_rules, .no_rules, .object_values => {
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

    fn compileSha256Rule(
        self: *Builder,
        object: std.json.ObjectMap,
        allow_input: bool,
        rule: *CompiledRule,
    ) anyerror!void {
        if (allow_input) {
            try definition_core.json.requireExactKeys(
                object,
                &.{
                    "op",
                    "input",
                    "path",
                    "mode",
                    "field",
                    "null",
                    "items",
                    "prefix",
                    "fragments",
                    "max_bytes",
                },
            );
        } else {
            try definition_core.json.requireExactKeys(
                object,
                &.{
                    "op",
                    "path",
                    "mode",
                    "field",
                    "null",
                    "items",
                    "prefix",
                    "fragments",
                    "max_bytes",
                },
            );
        }
        try definition_core.json.requireFields(
            object,
            &.{ "op", "mode", "field", "max_bytes" },
        );
        const mode = try definition_core.json.requiredString(object, "mode");
        rule.sha256_mode = if (std.mem.eql(
            u8,
            mode,
            "canonical-json-null",
        ))
            .canonical_json_null
        else if (std.mem.eql(u8, mode, "framed-items"))
            .framed_items
        else if (std.mem.eql(u8, mode, "framed-fields"))
            .framed_fields
        else
            return error.UnsupportedSha256Mode;
        rule.other_pointer_id = try self.internPointer(
            try definition_core.json.requiredString(object, "field"),
        );
        if (self.pointers.items[rule.other_pointer_id.?].raw.len == 0) {
            return error.Sha256FieldPointerEmpty;
        }
        rule.max_count = try optionalUnsigned(object, "max_bytes") orelse
            return error.MissingSha256Bound;
        if (rule.max_count.? == 0 or
            rule.max_count.? > max_sha256_subject_bytes)
        {
            return error.InvalidSha256Bound;
        }
        switch (rule.sha256_mode.?) {
            .canonical_json_null => {
                try definition_core.json.requireFields(
                    object,
                    &.{"null"},
                );
                if (object.get("items") != null or
                    object.get("prefix") != null or
                    object.get("fragments") != null)
                {
                    return error.ConflictingSha256ModeFields;
                }
                rule.path_ids = try self.allocator.alloc(u16, 1);
                rule.path_ids[0] = try self.internPointer(
                    try definition_core.json.requiredString(object, "null"),
                );
                if (self.pointers.items[rule.path_ids[0]].raw.len == 0) {
                    return error.Sha256NullPointerEmpty;
                }
            },
            .framed_items => {
                try definition_core.json.requireFields(
                    object,
                    &.{ "items", "prefix", "fragments" },
                );
                if (object.get("null") != null) {
                    return error.ConflictingSha256ModeFields;
                }
                rule.path_ids = try self.allocator.alloc(u16, 1);
                rule.path_ids[0] = try self.internPointer(
                    try definition_core.json.requiredString(object, "items"),
                );
                const prefix = try definition_core.json.requiredString(
                    object,
                    "prefix",
                );
                if (prefix.len > 4096) {
                    return error.Sha256PrefixBytesExceeded;
                }
                rule.sha256_prefix = try self.allocator.dupe(u8, prefix);
                rule.format_parts = try self.compileFormatParts(
                    try definition_core.json.field(object, "fragments"),
                    false,
                );
            },
            .framed_fields => {
                try definition_core.json.requireFields(
                    object,
                    &.{ "prefix", "fragments" },
                );
                if (object.get("null") != null or object.get("items") != null) {
                    return error.ConflictingSha256ModeFields;
                }
                const prefix = try definition_core.json.requiredString(
                    object,
                    "prefix",
                );
                if (prefix.len > 4096) {
                    return error.Sha256PrefixBytesExceeded;
                }
                rule.sha256_prefix = try self.allocator.dupe(u8, prefix);
                rule.format_parts = try self.compileFormatParts(
                    try definition_core.json.field(object, "fragments"),
                    false,
                );
                for (rule.format_parts) |part| switch (part) {
                    .literal, .parent => {},
                    .item, .value => return error.InvalidSha256FieldFragment,
                };
            },
        }
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
        .inputs = definition_plan.inputs,
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

pub fn compileEmbedded(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    inputs: []const definition.Input,
    raw_rules: std.json.Value,
    max_input_bytes: usize,
    max_records: usize,
    max_diagnostics: usize,
) !Plan {
    if (inputs.len == 0 or inputs.len > 64) {
        return error.InvalidInputCount;
    }
    if (max_input_bytes == 0 or max_input_bytes > 256 * 1024 * 1024 or
        max_records == 0 or max_records > 10_000_000 or
        max_diagnostics == 0 or max_diagnostics > 1024)
    {
        return error.InvalidEmbeddedValidationBounds;
    }
    var builder = Builder{
        .allocator = allocator,
        .definition_plan = definition_plan,
        .inputs = inputs,
    };
    errdefer builder.deinit();
    const rules = try definition_core.json.array(raw_rules);
    if (rules.items.len > 4096) {
        return error.InvalidEmbeddedRuleCount;
    }
    for (rules.items) |rule| try builder.compileRawRule(rule);
    const owned_inputs = try cloneInputs(allocator, inputs);
    errdefer {
        for (owned_inputs) |*input| input.deinit(allocator);
        allocator.free(owned_inputs);
    }
    const pointers = try builder.pointers.toOwnedSlice(allocator);
    errdefer {
        for (pointers) |*pointer| pointer.deinit(allocator);
        allocator.free(pointers);
    }
    const compiled_rules = try builder.rules.toOwnedSlice(allocator);
    return .{
        .inputs = owned_inputs,
        .pointers = pointers,
        .rules = compiled_rules,
        .max_input_bytes = max_input_bytes,
        .max_records = max_records,
        .max_diagnostics = max_diagnostics,
    };
}

fn findImportedDefinition(
    definition_plan: *const definition.Plan,
    id: []const u8,
) !u16 {
    for (definition_plan.imports, 0..) |imported, index| {
        if (std.mem.eql(u8, imported.id, id)) return @intCast(index);
    }
    return error.UnknownImportedDefinition;
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(29);
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
    if (try decoder.readU16() != 29) {
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

pub fn validateEmbeddedCachePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
    if (plan.inputs.len == 0 or plan.inputs.len > 64 or
        plan.max_input_bytes == 0 or
        plan.max_input_bytes > 256 * 1024 * 1024 or
        plan.max_records == 0 or plan.max_records > 10_000_000 or
        plan.max_diagnostics == 0 or plan.max_diagnostics > 1024)
    {
        return error.CacheValidationPlanMismatch;
    }
    for (plan.inputs, 0..) |input, index| {
        try definition_core.json.safeIdentifier(input.name, 128);
        if (input.codec != .json or input.max_bytes == 0 or
            input.max_bytes > plan.max_input_bytes or
            (index != 0 and
                std.mem.order(
                    u8,
                    plan.inputs[index - 1].name,
                    input.name,
                ) != .lt))
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
    for (rule.coverage_children) |child| {
        if (child.input_index != rule.other_input_index.? or
            !isItemOperator(child.operator))
        {
            return error.CacheValidationPlanMismatch;
        }
        try validateRuleAgainstDefinition(child, definition_plan);
    }
    for (rule.reference_targets) |target| {
        for (target.rules) |target_rule| {
            if (target_rule.input_index != rule.other_input_index.? or
                !isItemOperator(target_rule.operator))
            {
                return error.CacheValidationPlanMismatch;
            }
            try validateRuleAgainstDefinition(
                target_rule,
                definition_plan,
            );
        }
        for (target.match_rules) |match_rule| {
            if (match_rule.input_index != rule.other_input_index.? or
                !isItemOperator(match_rule.operator))
            {
                return error.CacheValidationPlanMismatch;
            }
            try validateRuleAgainstDefinition(
                match_rule,
                definition_plan,
            );
        }
        for (target.coverage_rules) |coverage_rule| {
            if (coverage_rule.input_index != rule.other_input_index.? or
                !isItemOperator(coverage_rule.operator))
            {
                return error.CacheValidationPlanMismatch;
            }
            try validateRuleAgainstDefinition(
                coverage_rule,
                definition_plan,
            );
        }
    }
    for (rule.reference_sources) |source| {
        for (source.rules) |source_rule| {
            if (source_rule.input_index != rule.input_index or
                !isItemOperator(source_rule.operator))
            {
                return error.CacheValidationPlanMismatch;
            }
            try validateRuleAgainstDefinition(
                source_rule,
                definition_plan,
            );
        }
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
    try encoder.writeBool(rule.allow_additional);
    try encoder.writeBool(rule.allow_null);
    try encoder.writeBool(rule.total_coverage);
    try encoder.writeBool(rule.reject_self_reference);
    try encoder.writeBool(rule.ignore_null_references);
    try encoder.writeBool(rule.then_nonempty);
    try encoder.writeCount(rule.children.len);
    for (rule.children) |child| {
        try encodeCompiledRule(encoder, child, depth);
    }
    try encoder.writeCount(rule.coverage_children.len);
    for (rule.coverage_children) |child| {
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
    try encodeCompiledFormatParts(encoder, rule.format_parts);
    try encoder.writeCount(rule.regex_patterns.len);
    for (rule.regex_patterns) |pattern| {
        try encoder.writeCount(pattern.atoms.len);
        for (pattern.atoms) |atom| {
            for (atom.bytes) |word| try encoder.writeU64(word);
            try encoder.writeEnum(atom.quantifier);
        }
    }
    try encoder.writeBool(rule.sha256_mode != null);
    if (rule.sha256_mode) |mode| try encoder.writeEnum(mode);
    try encoder.writeOptionalBytes(rule.sha256_prefix);
    try encoder.writeCount(rule.reference_sources.len);
    for (rule.reference_sources) |source| {
        try encoder.writeU16(source.pointer_id);
        try writeOptionalU16(encoder, source.items_pointer_id);
        try encoder.writeU16(source.reference_pointer_id);
        try encoder.writeBool(source.optional);
        try encoder.writeCount(source.rules.len);
        for (source.rules) |source_rule| {
            try encodeCompiledRule(encoder, source_rule, depth);
        }
        try encodeCompiledFormatParts(encoder, source.format_parts);
    }
    try encoder.writeCount(rule.reference_targets.len);
    for (rule.reference_targets) |target| {
        try encoder.writeU16(target.pointer_id);
        try encoder.writeBool(target.optional);
        try writeOptionalU16(encoder, target.items_pointer_id);
        try writeOptionalU16(encoder, target.key_pointer_id);
        try writeOptionalU16(encoder, target.coverage_key_pointer_id);
        try encoder.writeCount(target.rules.len);
        for (target.rules) |target_rule| {
            try encodeCompiledRule(encoder, target_rule, depth);
        }
        try encoder.writeCount(target.match_rules.len);
        for (target.match_rules) |match_rule| {
            try encodeCompiledRule(encoder, match_rule, depth);
        }
        try encoder.writeCount(target.coverage_rules.len);
        for (target.coverage_rules) |coverage_rule| {
            try encodeCompiledRule(encoder, coverage_rule, depth);
        }
        try encodeCompiledFormatParts(encoder, target.format_parts);
    }
    try encoder.writeBool(rule.imported_plan != null);
    if (rule.imported_plan) |imported_plan| {
        try encodeCachePlan(imported_plan, encoder, depth + 1);
    }
}

fn encodeCompiledFormatParts(
    encoder: *definition_core.cache.Encoder,
    parts: []const CompiledFormatPart,
) !void {
    try encoder.writeCount(parts.len);
    for (parts) |part| {
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
            .value => try encoder.writeByte(3),
        }
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
    const allow_additional = try decoder.readBool();
    const allow_null = try decoder.readBool();
    const total_coverage = try decoder.readBool();
    const reject_self_reference = try decoder.readBool();
    const ignore_null_references = try decoder.readBool();
    const then_nonempty = try decoder.readBool();
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
    const coverage_children = try decodeCacheRules(
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
        for (coverage_children) |*child| child.deinit(allocator);
        allocator.free(coverage_children);
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
    const format_parts = try decodeCompiledFormatParts(allocator, decoder);
    errdefer {
        for (format_parts) |*part| part.deinit(allocator);
        allocator.free(format_parts);
    }
    const regex_patterns = try decodeCompiledRegexPatterns(
        allocator,
        decoder,
    );
    errdefer {
        for (regex_patterns) |*pattern| pattern.deinit(allocator);
        allocator.free(regex_patterns);
    }
    const sha256_mode = if (try decoder.readBool())
        try decoder.readEnum(Sha256Mode)
    else
        null;
    const sha256_prefix = try decoder.readOptionalBytesAlloc(
        allocator,
        4096,
    );
    errdefer if (sha256_prefix) |prefix| allocator.free(prefix);
    const reference_source_count = try decoder.readCount(64);
    const reference_sources = try allocator.alloc(
        CompiledReferenceSource,
        reference_source_count,
    );
    var reference_sources_initialized: usize = 0;
    errdefer {
        for (reference_sources[0..reference_sources_initialized]) |*source| {
            source.deinit(allocator);
        }
        allocator.free(reference_sources);
    }
    for (reference_sources) |*source| {
        const source_pointer_id = try decoder.readU16();
        const source_items_pointer_id = try readOptionalU16(decoder);
        const reference_pointer_id = try decoder.readU16();
        const source_optional = try decoder.readBool();
        const source_rules = try decodeCacheRules(
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
            for (source_rules) |*source_rule| {
                source_rule.deinit(allocator);
            }
            allocator.free(source_rules);
        }
        source.* = .{
            .pointer_id = source_pointer_id,
            .items_pointer_id = source_items_pointer_id,
            .reference_pointer_id = reference_pointer_id,
            .optional = source_optional,
            .rules = source_rules,
            .format_parts = try decodeCompiledFormatParts(
                allocator,
                decoder,
            ),
        };
        reference_sources_initialized += 1;
    }
    const reference_target_count = try decoder.readCount(64);
    const reference_targets = try allocator.alloc(
        CompiledReferenceTarget,
        reference_target_count,
    );
    var reference_targets_initialized: usize = 0;
    errdefer {
        for (reference_targets[0..reference_targets_initialized]) |*target| {
            target.deinit(allocator);
        }
        allocator.free(reference_targets);
    }
    for (reference_targets) |*target| {
        const target_pointer_id = try decoder.readU16();
        const target_optional = try decoder.readBool();
        const items_pointer_id = try readOptionalU16(decoder);
        const key_pointer_id = try readOptionalU16(decoder);
        const coverage_key_pointer_id = try readOptionalU16(decoder);
        const target_rules = try decodeCacheRules(
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
            for (target_rules) |*target_rule| {
                target_rule.deinit(allocator);
            }
            allocator.free(target_rules);
        }
        const match_rules = try decodeCacheRules(
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
            for (match_rules) |*match_rule| {
                match_rule.deinit(allocator);
            }
            allocator.free(match_rules);
        }
        const coverage_rules = try decodeCacheRules(
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
            for (coverage_rules) |*coverage_rule| {
                coverage_rule.deinit(allocator);
            }
            allocator.free(coverage_rules);
        }
        const target_format_parts =
            try decodeCompiledFormatParts(allocator, decoder);
        errdefer {
            for (target_format_parts) |*part| part.deinit(allocator);
            allocator.free(target_format_parts);
        }
        target.* = .{
            .pointer_id = target_pointer_id,
            .optional = target_optional,
            .items_pointer_id = items_pointer_id,
            .key_pointer_id = key_pointer_id,
            .coverage_key_pointer_id = coverage_key_pointer_id,
            .rules = target_rules,
            .match_rules = match_rules,
            .coverage_rules = coverage_rules,
            .format_parts = target_format_parts,
        };
        reference_targets_initialized += 1;
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
        .allow_additional = allow_additional,
        .allow_null = allow_null,
        .total_coverage = total_coverage,
        .reject_self_reference = reject_self_reference,
        .ignore_null_references = ignore_null_references,
        .then_nonempty = then_nonempty,
        .children = children,
        .coverage_children = coverage_children,
        .variants = variants,
        .format_parts = format_parts,
        .regex_patterns = regex_patterns,
        .sha256_mode = sha256_mode,
        .sha256_prefix = sha256_prefix,
        .reference_sources = reference_sources,
        .reference_targets = reference_targets,
    };
    try validateCachedRule(rule, input_count, pointer_count);
    return rule;
}

fn decodeCompiledFormatParts(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]CompiledFormatPart {
    const count = try decoder.readCount(32);
    const parts = try allocator.alloc(CompiledFormatPart, count);
    var initialized: usize = 0;
    errdefer {
        for (parts[0..initialized]) |*part| part.deinit(allocator);
        allocator.free(parts);
    }
    var literal_bytes: usize = 0;
    for (parts) |*part| {
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
            3 => .value,
            else => return error.CachePathFormatPartInvalid,
        };
        initialized += 1;
    }
    return parts;
}

fn decodeCompiledRegexPatterns(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]CompiledRegexPattern {
    const count = try decoder.readCount(32);
    if (count == 0) return allocator.alloc(CompiledRegexPattern, 0);
    const patterns = try allocator.alloc(CompiledRegexPattern, count);
    var initialized: usize = 0;
    var total_atoms: usize = 0;
    errdefer {
        for (patterns[0..initialized]) |*pattern| {
            pattern.deinit(allocator);
        }
        allocator.free(patterns);
    }
    for (patterns) |*pattern| {
        const atom_count = try decoder.readCount(255);
        if (atom_count == 0) return error.CacheRegexPatternInvalid;
        total_atoms = std.math.add(
            usize,
            total_atoms,
            atom_count,
        ) catch return error.CacheRegexPatternInvalid;
        if (total_atoms > 256) return error.CacheRegexPatternInvalid;
        const atoms = try allocator.alloc(CompiledRegexAtom, atom_count);
        errdefer allocator.free(atoms);
        for (atoms) |*atom| {
            for (&atom.bytes) |*word| word.* = try decoder.readU64();
            atom.quantifier = try decoder.readEnum(RegexQuantifier);
            if (regexByteSetEmpty(atom.bytes)) {
                return error.CacheRegexPatternInvalid;
            }
        }
        pattern.* = .{ .atoms = atoms };
        initialized += 1;
    }
    return patterns;
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
) anyerror!void {
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
        .required_field, .field_absent => if (rule.pointer_id == null) {
            return error.CacheRuleConfigurationInvalid;
        },
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
        .regex => if (rule.max_count == null or
            rule.max_count.? == 0 or
            rule.max_count.? > max_regex_subject_bytes or
            rule.regex_patterns.len == 0 or
            rule.regex_patterns.len > 32)
        {
            return error.CacheRuleConfigurationInvalid;
        } else {
            var total_atoms: usize = 0;
            for (rule.regex_patterns) |pattern| {
                if (pattern.atoms.len == 0 or pattern.atoms.len > 255) {
                    return error.CacheRuleConfigurationInvalid;
                }
                total_atoms = std.math.add(
                    usize,
                    total_atoms,
                    pattern.atoms.len,
                ) catch return error.CacheRuleConfigurationInvalid;
                if (total_atoms > 256) {
                    return error.CacheRuleConfigurationInvalid;
                }
                for (pattern.atoms) |atom| {
                    if (regexByteSetEmpty(atom.bytes)) {
                        return error.CacheRuleConfigurationInvalid;
                    }
                }
            }
        },
        .sha256 => if (rule.max_count == null or
            rule.max_count.? == 0 or
            rule.max_count.? > max_sha256_subject_bytes or
            rule.other_pointer_id == null or
            rule.sha256_mode == null)
        {
            return error.CacheRuleConfigurationInvalid;
        } else switch (rule.sha256_mode.?) {
            .canonical_json_null => {
                if (rule.path_ids.len != 1 or
                    rule.sha256_prefix != null or
                    rule.format_parts.len != 0)
                {
                    return error.CacheRuleConfigurationInvalid;
                }
            },
            .framed_items => {
                if (rule.path_ids.len != 1 or
                    rule.sha256_prefix == null or
                    rule.sha256_prefix.?.len > 4096 or
                    rule.format_parts.len == 0 or
                    rule.format_parts.len > 32)
                {
                    return error.CacheRuleConfigurationInvalid;
                }
            },
            .framed_fields => {
                if (rule.path_ids.len != 0 or
                    rule.sha256_prefix == null or
                    rule.sha256_prefix.?.len > 4096 or
                    rule.format_parts.len == 0 or
                    rule.format_parts.len > 32)
                {
                    return error.CacheRuleConfigurationInvalid;
                }
                for (rule.format_parts) |part| switch (part) {
                    .literal, .parent => {},
                    .item, .value => {
                        return error.CacheRuleConfigurationInvalid;
                    },
                };
            },
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
        .sorted => if (rule.pointer_id == null or
            rule.path_ids.len != 0)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .set_equality,
        .subset,
        .superset,
        .disjoint,
        .path_scope_subset,
        .path_scope_disjoint,
        .member_of,
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
        .exactly_one, .at_least_one => {
            const field_mode = rule.path_ids.len != 0 and
                rule.pointer_id == null and rule.children.len == 0;
            const collection_mode = rule.path_ids.len == 0 and
                rule.pointer_id != null and rule.children.len != 0;
            if (!field_mode and !collection_mode) {
                return error.CacheRuleConfigurationInvalid;
            }
        },
        .keyed_unique => {
            const collection_mode = rule.pointer_id != null and
                rule.other_pointer_id != null and
                rule.reference_sources.len == 0;
            const source_mode = rule.pointer_id == null and
                rule.other_pointer_id == null and
                rule.reference_sources.len >= 2;
            if (!collection_mode and !source_mode) {
                return error.CacheRuleConfigurationInvalid;
            }
        },
        .keyed_join => if (rule.pointer_id == null or
            rule.other_pointer_id == null or
            rule.path_ids.len != 3)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .declared_field_values => if (rule.pointer_id == null or
            rule.other_pointer_id == null or
            rule.path_ids.len < 2 or
            rule.scalar_kind == null or
            (rule.scalar_kind.? != .integer and
                rule.scalar_kind.? != .number) or
            (rule.min_number == null and rule.max_number == null))
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .reference_exists => if (rule.other_input_index == null or
            (rule.reference_sources.len == 0 and
                (rule.pointer_id == null or
                    rule.other_pointer_id == null)) or
            (rule.reference_sources.len != 0 and
                (rule.pointer_id != null or
                    rule.other_pointer_id != null)))
        {
            return error.CacheRuleConfigurationInvalid;
        } else if ((rule.reference_targets.len == 0 and
            rule.path_ids.len != 2 and rule.path_ids.len != 3) or
            (rule.reference_targets.len != 0 and
                (rule.path_ids.len != 0 or
                    rule.children.len != 0 or
                    rule.coverage_children.len != 0)))
        {
            return error.CacheRuleConfigurationInvalid;
        } else if (rule.reject_self_reference and rule.path_ids.len != 2) {
            return error.CacheRuleConfigurationInvalid;
        } else if (rule.coverage_children.len != 0 and
            !rule.total_coverage)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .implies => if (rule.pointer_id == null or
            rule.other_input_index == null or
            rule.other_pointer_id == null or
            rule.values.len > 2 or
            (rule.min_count != null and rule.min_count.? != 1) or
            (rule.min_count != null and rule.values.len > 1) or
            (rule.then_nonempty and
                (rule.values.len == 2 or
                    (rule.min_count != null and rule.values.len == 1))))
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
        .predecessor_successor => if (rule.pointer_id == null or
            rule.other_pointer_id == null or
            rule.path_ids.len != 8)
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
        .one_of, .all_rules, .any_rules, .no_rules, .object_values => if (rule.pointer_id == null or
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
    if (rule.operator != .exact_object and rule.allow_additional) {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .optional_field and rule.allow_null) {
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
        rule.operator != .object_values and
        rule.operator != .reference_exists and
        rule.operator != .keyed_join and
        rule.operator != .exactly_one and
        rule.operator != .at_least_one and
        rule.children.len != 0)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .tagged_union and rule.variants.len != 0) {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .path_format and
        rule.operator != .sha256 and
        rule.format_parts.len != 0)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .sha256 and
        (rule.sha256_mode != null or rule.sha256_prefix != null))
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .regex and rule.regex_patterns.len != 0) {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .reference_exists and
        rule.ignore_null_references)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .implies and rule.then_nonempty) {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .reference_exists and
        rule.coverage_children.len != 0)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .reference_exists and
        rule.operator != .keyed_unique and
        rule.reference_sources.len != 0)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .reference_exists and
        rule.reference_targets.len != 0)
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
            .value => return error.CacheRuleConfigurationInvalid,
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
    for (rule.coverage_children) |child| {
        if (child.input_index != rule.other_input_index.? or
            !isItemOperator(child.operator))
        {
            return error.CacheRuleConfigurationInvalid;
        }
        try validateCachedRule(child, input_count, pointer_count);
    }
    for (rule.reference_targets) |target| {
        try validateCachedReferenceTarget(
            target,
            rule.other_input_index.?,
            rule.total_coverage,
            input_count,
            pointer_count,
        );
    }
    for (rule.reference_sources) |source| {
        if (source.pointer_id >= pointer_count or
            source.reference_pointer_id >= pointer_count or
            (source.items_pointer_id != null and
                source.items_pointer_id.? >= pointer_count))
        {
            return error.CacheRuleIndexInvalid;
        }
        try validateCachedFormatParts(
            source.format_parts,
            pointer_count,
            true,
        );
        for (source.rules) |source_rule| {
            if (source_rule.input_index != rule.input_index or
                !isItemOperator(source_rule.operator))
            {
                return error.CacheRuleConfigurationInvalid;
            }
            try validateCachedRule(
                source_rule,
                input_count,
                pointer_count,
            );
        }
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
                !isValidationOperator(imported_rule.operator))
            {
                return error.CacheRuleConfigurationInvalid;
            }
        }
    }
}

fn validateCachedReferenceTarget(
    target: CompiledReferenceTarget,
    input_index: u8,
    total_coverage: bool,
    input_count: usize,
    pointer_count: usize,
) anyerror!void {
    if (target.pointer_id >= pointer_count or
        (target.items_pointer_id != null and
            target.items_pointer_id.? >= pointer_count) or
        (target.key_pointer_id != null and
            target.key_pointer_id.? >= pointer_count) or
        (target.coverage_key_pointer_id != null and
            target.coverage_key_pointer_id.? >= pointer_count) or
        ((target.key_pointer_id == null) ==
            (target.format_parts.len == 0)) or
        target.rules.len > 64 or
        target.match_rules.len > 64 or
        target.coverage_rules.len > 64 or
        (target.coverage_rules.len != 0 and !total_coverage))
    {
        return error.CacheRuleConfigurationInvalid;
    }
    try validateCachedFormatParts(
        target.format_parts,
        pointer_count,
        false,
    );
    for (target.rules) |rule| {
        if (rule.input_index != input_index or
            !isItemOperator(rule.operator))
        {
            return error.CacheRuleConfigurationInvalid;
        }
        try validateCachedRule(rule, input_count, pointer_count);
    }
    for (target.match_rules) |rule| {
        if (rule.input_index != input_index or
            !isItemOperator(rule.operator))
        {
            return error.CacheRuleConfigurationInvalid;
        }
        try validateCachedRule(rule, input_count, pointer_count);
    }
    for (target.coverage_rules) |rule| {
        if (rule.input_index != input_index or
            !isItemOperator(rule.operator))
        {
            return error.CacheRuleConfigurationInvalid;
        }
        try validateCachedRule(rule, input_count, pointer_count);
    }
}

fn validateCachedFormatParts(
    parts: []const CompiledFormatPart,
    pointer_count: usize,
    allow_value: bool,
) !void {
    if (parts.len > 32) return error.CacheRuleConfigurationInvalid;
    var literal_bytes: usize = 0;
    for (parts) |part| {
        switch (part) {
            .literal => |literal| {
                if (literal.len == 0) {
                    return error.CacheRuleConfigurationInvalid;
                }
                literal_bytes = std.math.add(
                    usize,
                    literal_bytes,
                    literal.len,
                ) catch return error.CacheRuleConfigurationInvalid;
                if (literal_bytes > 4096) {
                    return error.CacheRuleConfigurationInvalid;
                }
            },
            .parent, .item => |pointer_id| {
                if (pointer_id >= pointer_count) {
                    return error.CacheRuleIndexInvalid;
                }
            },
            .value => if (!allow_value) {
                return error.CacheRuleConfigurationInvalid;
            },
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
    borrowed_json: ?std.json.Value = null,

    fn deinit(self: *LoadedInput) void {
        if (self.parsed_json) |*parsed| parsed.deinit();
        self.* = undefined;
    }

    fn json(self: *const LoadedInput) ?std.json.Value {
        if (self.parsed_json) |parsed| return parsed.value;
        return self.borrowed_json;
    }

    fn jsonPtr(self: *LoadedInput) ?*std.json.Value {
        if (self.parsed_json) |*parsed| return &parsed.value;
        if (self.borrowed_json != null) return &self.borrowed_json.?;
        return null;
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
        return self.loaded[input_index].json();
    }

    pub fn inputJsonPtr(
        self: *Execution,
        input_index: usize,
    ) ?*std.json.Value {
        if (input_index >= self.loaded.len) return null;
        return self.loaded[input_index].jsonPtr();
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

pub const InputValue = struct {
    name: []const u8,
    value: std.json.Value,
};

pub fn executeValues(
    allocator: std.mem.Allocator,
    validation_plan: *const Plan,
    values: []const InputValue,
) !Execution {
    var diagnostics = definition_core.diagnostics.Collector.init(allocator, .{
        .max_count = validation_plan.max_diagnostics,
        .max_total_bytes = 64 * 1024,
        .max_message_bytes = 2048,
    });
    errdefer diagnostics.deinit();
    const loaded = try allocator.alloc(LoadedInput, validation_plan.inputs.len);
    @memset(loaded, .{});
    errdefer allocator.free(loaded);
    const seen = try allocator.alloc(bool, validation_plan.inputs.len);
    defer allocator.free(seen);
    @memset(seen, false);
    for (values) |value| {
        const input_index = findInput(
            validation_plan.inputs,
            value.name,
        ) orelse return error.UnknownInputBinding;
        if (seen[input_index]) return error.DuplicateInputBinding;
        seen[input_index] = true;
        loaded[input_index].borrowed_json = value.value;
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
    return .{
        .allocator = allocator,
        .loaded = loaded,
        .input_digests = try allocator.alloc(InputDigest, 0),
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
    const root = loaded[rule.input_index].json() orelse return;
    const target = if (rule.pointer_id) |pointer_id|
        resolve(root, plan.pointers[pointer_id])
    else
        root;
    const path = if (rule.pointer_id) |pointer_id| plan.pointers[pointer_id].raw else "";
    const valid = switch (rule.operator) {
        .required_field => target != null,
        .field_absent => target == null,
        .optional_field => if (target) |value|
            (rule.allow_null and value == .null) or
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
        .regex => if (target) |value| regexHolds(value, rule) else false,
        .sha256 => if (target) |value|
            try sha256Holds(allocator, plan, rule, value)
        else
            false,
        .bounded_number => if (target) |value| boundedNumber(value, rule) else false,
        .bounded_array => if (target) |value| boundedCount(value, .array, rule) else false,
        .bounded_object => if (target) |value| boundedCount(value, .object, rule) else false,
        .enum_value => if (target) |value| enumContains(rule.values, value) else false,
        .digest => if (target) |value| validateScalar(value, .digest) else false,
        .timestamp => if (target) |value| validateScalar(value, .timestamp) else false,
        .safe_identifier => if (target) |value| safeIdentifier(value, rule) else false,
        .safe_relative_path => if (target) |value| safeRelativePath(value, rule) else false,
        .unique => if (target) |value| arrayUnique(value) else false,
        .sorted => if (target) |value|
            arraySorted(value, if (rule.other_pointer_id) |pointer_id|
                plan.pointers[pointer_id]
            else
                null)
        else
            false,
        .keyed_unique => if (rule.reference_sources.len == 0)
            if (target) |value|
                try keyedUnique(
                    allocator,
                    value,
                    plan.pointers[rule.other_pointer_id.?],
                    plan.max_records,
                )
            else
                false
        else
            try keyedUniqueSources(allocator, plan, root, rule),
        .keyed_join => try selectedKeyedJoin(
            allocator,
            plan,
            root,
            rule,
        ),
        .declared_field_values => if (target) |value|
            try declaredFieldValuesHold(
                allocator,
                plan,
                root,
                rule,
                value,
            )
        else
            false,
        .reference_exists => if (target) |value|
            try referencesExist(
                allocator,
                plan,
                rule,
                value,
                root,
                loaded[rule.other_input_index.?].json() orelse return,
            )
        else
            false,
        .implies => implicationHolds(
            plan,
            root,
            loaded[rule.other_input_index.?].json() orelse return,
            rule,
        ),
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
        .predecessor_successor => try predecessorSuccessorHolds(
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
        .object_values => if (target) |value|
            try objectValuesHold(
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
        .path_scope_subset,
        .path_scope_disjoint,
        .member_of,
        .field_equal,
        .field_not_equal,
        .cross_input_equal,
        => compareRule(plan, loaded, rule),
        .exactly_one, .at_least_one => if (rule.children.len == 0)
            countPresent(plan, root, rule)
        else
            try countMatching(allocator, plan, root, rule),
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

fn objectValuesHold(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: CompiledRule,
    value: std.json.Value,
) anyerror!bool {
    const object = switch (value) {
        .object => |object| object,
        else => return false,
    };
    if (object.count() > plan.max_records) return false;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!try itemRulesHold(
            allocator,
            plan,
            rule.children,
            entry.value_ptr.*,
        )) {
            return false;
        }
    }
    return true;
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
                    .value => return false,
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
        .field_absent => target == null,
        .optional_field => if (target) |value|
            (rule.allow_null and value == .null) or
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
        .regex => if (target) |value| regexHolds(value, rule) else false,
        .sha256 => if (target) |value|
            try sha256Holds(allocator, plan, rule, value)
        else
            false,
        .bounded_number => if (target) |value| boundedNumber(value, rule) else false,
        .bounded_array => if (target) |value| boundedCount(value, .array, rule) else false,
        .bounded_object => if (target) |value| boundedCount(value, .object, rule) else false,
        .enum_value => if (target) |value| enumContains(rule.values, value) else false,
        .digest => if (target) |value| validateScalar(value, .digest) else false,
        .timestamp => if (target) |value| validateScalar(value, .timestamp) else false,
        .safe_identifier => if (target) |value| safeIdentifier(value, rule) else false,
        .safe_relative_path => if (target) |value| safeRelativePath(value, rule) else false,
        .unique => if (target) |value| arrayUnique(value) else false,
        .sorted => if (target) |value|
            arraySorted(value, if (rule.other_pointer_id) |pointer_id|
                plan.pointers[pointer_id]
            else
                null)
        else
            false,
        .keyed_unique => if (target) |value|
            try keyedUnique(
                allocator,
                value,
                plan.pointers[rule.other_pointer_id.?],
                plan.max_records,
            )
        else
            false,
        .declared_field_values => if (target) |value|
            try declaredFieldValuesHold(
                allocator,
                plan,
                root,
                rule,
                value,
            )
        else
            false,
        .reference_exists => if (target) |value|
            try referencesExist(
                allocator,
                plan,
                rule,
                value,
                root,
                root,
            )
        else
            false,
        .implies => implicationHolds(plan, root, root, rule),
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
        .set_equality,
        .subset,
        .superset,
        .disjoint,
        .path_scope_subset,
        .path_scope_disjoint,
        .member_of,
        .field_equal,
        .field_not_equal,
        .cross_input_equal,
        => compareRuleRoots(plan, rule, root, root),
        .exactly_one, .at_least_one => if (rule.children.len == 0)
            countPresent(plan, root, rule)
        else
            try countMatching(allocator, plan, root, rule),
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
        .object_values => if (target) |value|
            objectValuesHold(allocator, plan, rule, value)
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
    if (plan.inputs.len != 1) return error.ImportedDefinitionNotReusable;
    var execution = try executeValues(
        allocator,
        plan,
        &.{.{
            .name = plan.inputs[0].name,
            .value = root,
        }},
    );
    defer execution.deinit();
    return execution.isValid();
}

fn compareRule(
    plan: *const Plan,
    loaded: []const LoadedInput,
    rule: CompiledRule,
) bool {
    const left_root = loaded[rule.input_index].json() orelse return false;
    const right_root = loaded[rule.other_input_index.?].json() orelse return false;
    return compareRuleRoots(plan, rule, left_root, right_root);
}

fn compareRuleRoots(
    plan: *const Plan,
    rule: CompiledRule,
    left_root: std.json.Value,
    right_root: std.json.Value,
) bool {
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
            if (!compareValues(
                rule.operator,
                left,
                right,
                plan.max_records,
            )) return false;
        }
        return true;
    }
    const left = resolve(left_root, plan.pointers[rule.pointer_id.?]) orelse return false;
    const right = resolve(right_root, plan.pointers[rule.other_pointer_id.?]) orelse return false;
    return compareValues(
        rule.operator,
        left,
        right,
        plan.max_records,
    );
}

fn compareValues(
    operator: definition.Operator,
    left: std.json.Value,
    right: std.json.Value,
    max_records: usize,
) bool {
    return switch (operator) {
        .field_equal, .cross_input_equal => valuesEqual(left, right),
        .field_not_equal => !valuesEqual(left, right),
        .set_equality => setSubset(left, right, max_records) and
            setSubset(right, left, max_records),
        .subset => setSubset(left, right, max_records),
        .superset => setSubset(right, left, max_records),
        .disjoint => setsDisjoint(left, right, max_records),
        .path_scope_subset => pathScopesContain(
            left,
            right,
            max_records,
        ),
        .path_scope_disjoint => pathScopesDisjoint(
            left,
            right,
            max_records,
        ),
        .member_of => valueMemberOf(left, right, max_records),
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

fn countMatching(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
    rule: CompiledRule,
) !bool {
    const items = switch (resolve(
        root,
        plan.pointers[rule.pointer_id.?],
    ) orelse return false) {
        .array => |array| array.items,
        else => return false,
    };
    if (items.len > plan.max_records) return false;
    var count: usize = 0;
    for (items) |item| {
        if (try itemRulesHold(allocator, plan, rule.children, item)) {
            count += 1;
            if (rule.operator == .exactly_one and count > 1) return false;
            if (rule.operator == .at_least_one) return true;
        }
    }
    return count == 1;
}

fn implicationHolds(
    plan: *const Plan,
    condition_root: std.json.Value,
    consequent_root: std.json.Value,
    rule: CompiledRule,
) bool {
    const condition = resolve(
        condition_root,
        plan.pointers[rule.pointer_id.?],
    ) orelse return true;
    if (rule.min_count == null and rule.values.len >= 1 and
        !enumEqual(rule.values[0], condition))
    {
        return true;
    }
    if (rule.min_count != null and !valueNonempty(condition)) return true;
    const consequent = resolve(
        consequent_root,
        plan.pointers[rule.other_pointer_id.?],
    ) orelse return false;
    const expected_consequent = if (rule.min_count != null)
        if (rule.values.len == 1) rule.values[0] else null
    else if (rule.values.len == 2)
        rule.values[1]
    else
        null;
    if (expected_consequent) |expected| {
        return enumEqual(expected, consequent);
    }
    return !rule.then_nonempty or valueNonempty(consequent);
}

fn valueNonempty(value: std.json.Value) bool {
    return switch (value) {
        .string => |text| text.len != 0,
        .array => |array| array.items.len != 0,
        .object => |object| object.count() != 0,
        else => false,
    };
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
        (!rule.allow_additional and
            object.count() > rule.keys.len + rule.optional_keys.len))
    {
        return false;
    }
    for (rule.keys) |key| if (!object.contains(key)) return false;
    if (rule.allow_additional) return true;
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

fn regexHolds(value: std.json.Value, rule: CompiledRule) bool {
    const text = switch (value) {
        .string => |text| text,
        else => return false,
    };
    if (text.len > rule.max_count.?) return false;
    for (rule.regex_patterns) |pattern| {
        if (compiledRegexMatches(text, pattern)) return true;
    }
    return false;
}

fn sha256Holds(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: CompiledRule,
    value: std.json.Value,
) !bool {
    if (plan.pointers[rule.other_pointer_id.?].raw.len == 0) return false;
    const expected_value = resolve(
        value,
        plan.pointers[rule.other_pointer_id.?],
    ) orelse return false;
    const expected = switch (expected_value) {
        .string => |text| text,
        else => return false,
    };
    if (!validateScalar(expected_value, .digest)) return false;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    switch (rule.sha256_mode.?) {
        .canonical_json_null => {
            if (plan.pointers[rule.path_ids[0]].raw.len == 0) return false;
            var mutable = value;
            const null_field = definition_core.json_pointer.lookupPtr(
                &mutable,
                plan.pointers[rule.path_ids[0]],
            ) orelse return false;
            const preserved = null_field.*;
            defer null_field.* = preserved;
            null_field.* = .null;
            const canonical =
                definition_core.canonical_json.canonicalJsonAlloc(
                    allocator,
                    mutable,
                ) catch |err| switch (err) {
                    error.WriteFailed => return error.OutOfMemory,
                    else => return err,
                };
            defer allocator.free(canonical);
            if (canonical.len > rule.max_count.?) return false;
            hasher.update(canonical);
        },
        .framed_items => {
            if (plan.pointers[rule.path_ids[0]].raw.len == 0) return false;
            const prefix = rule.sha256_prefix.?;
            var total_bytes = prefix.len;
            if (total_bytes > rule.max_count.?) return false;
            hasher.update(prefix);
            const items = switch (resolve(
                value,
                plan.pointers[rule.path_ids[0]],
            ) orelse return false) {
                .array => |array| array.items,
                else => return false,
            };
            if (items.len > plan.max_records) return false;
            for (items) |item| {
                const key: FormattedReferenceKey = .{
                    .parent = value,
                    .item = item,
                    .value = item,
                    .parts = rule.format_parts,
                };
                for (rule.format_parts) |part| {
                    const fragment = formattedReferenceFragment(
                        plan,
                        key,
                        part,
                    ) orelse return false;
                    total_bytes = std.math.add(
                        usize,
                        total_bytes,
                        fragment.len,
                    ) catch return false;
                    if (total_bytes > rule.max_count.?) return false;
                    hasher.update(fragment);
                }
            }
        },
        .framed_fields => {
            const prefix = rule.sha256_prefix.?;
            var total_bytes = prefix.len;
            if (total_bytes > rule.max_count.?) return false;
            hasher.update(prefix);
            const key: FormattedReferenceKey = .{
                .parent = value,
                .item = value,
                .value = value,
                .parts = rule.format_parts,
            };
            for (rule.format_parts) |part| {
                const fragment = formattedReferenceFragment(
                    plan,
                    key,
                    part,
                ) orelse return false;
                total_bytes = std.math.add(
                    usize,
                    total_bytes,
                    fragment.len,
                ) catch return false;
                if (total_bytes > rule.max_count.?) return false;
                hasher.update(fragment);
            }
        },
    }
    return sha256FinalMatches(&hasher, expected);
}

fn sha256FinalMatches(
    hasher: *std.crypto.hash.sha2.Sha256,
    expected: []const u8,
) bool {
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    var computed: [71]u8 = undefined;
    @memcpy(computed[0..7], "sha256:");
    @memcpy(computed[7..], &hex);
    return std.mem.eql(u8, expected, &computed);
}

fn compiledRegexMatches(
    text: []const u8,
    pattern: CompiledRegexPattern,
) bool {
    var active: [4]u64 = @splat(0);
    regexStateSet(&active, 0);
    regexEpsilonClosure(pattern, &active);
    for (text) |byte| {
        var next: [4]u64 = @splat(0);
        for (pattern.atoms, 0..) |atom, index| {
            if (!regexStateContains(active, index) or
                !regexByteSetContains(atom.bytes, byte))
            {
                continue;
            }
            switch (atom.quantifier) {
                .one, .zero_or_one => regexStateSet(&next, index + 1),
                .zero_or_more, .one_or_more => {
                    regexStateSet(&next, index);
                    regexStateSet(&next, index + 1);
                },
            }
        }
        active = next;
        regexEpsilonClosure(pattern, &active);
    }
    regexEpsilonClosure(pattern, &active);
    return regexStateContains(active, pattern.atoms.len);
}

fn regexEpsilonClosure(
    pattern: CompiledRegexPattern,
    states: *[4]u64,
) void {
    for (pattern.atoms, 0..) |atom, index| {
        if (!regexStateContains(states.*, index)) continue;
        switch (atom.quantifier) {
            .zero_or_one, .zero_or_more => {
                regexStateSet(states, index + 1);
            },
            .one, .one_or_more => {},
        }
    }
}

fn regexStateSet(states: *[4]u64, state: usize) void {
    const word = state / 64;
    const bit: u6 = @intCast(state % 64);
    states[word] |= @as(u64, 1) << bit;
}

fn regexStateContains(states: [4]u64, state: usize) bool {
    const word = state / 64;
    const bit: u6 = @intCast(state % 64);
    return states[word] & (@as(u64, 1) << bit) != 0;
}

fn boundedNumber(value: std.json.Value, rule: CompiledRule) bool {
    const number = jsonNumber(value) orelse return false;
    if (rule.min_number) |minimum| if (number < minimum) return false;
    if (rule.max_number) |maximum| if (number > maximum) return false;
    return true;
}

fn declaredFieldValuesHold(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
    rule: CompiledRule,
    target_value: std.json.Value,
) !bool {
    const targets = switch (target_value) {
        .array => |array| array.items,
        else => return false,
    };
    const declarations_value = resolve(
        root,
        plan.pointers[rule.path_ids[0]],
    ) orelse return false;
    const declarations = switch (declarations_value) {
        .array => |array| array.items,
        else => return false,
    };
    if (targets.len > plan.max_records or
        declarations.len > plan.max_records)
    {
        return false;
    }

    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(allocator);
    for (declarations) |declaration| {
        var name: ?[]const u8 = null;
        for (rule.path_ids[1..]) |pointer_id| {
            const candidate = resolve(
                declaration,
                plan.pointers[pointer_id],
            ) orelse continue;
            const text = switch (candidate) {
                .string => |value| value,
                else => return false,
            };
            if (text.len == 0 or name != null) return false;
            name = text;
        }
        const declaration_name = name orelse return false;
        const entry = try names.getOrPut(allocator, declaration_name);
        if (entry.found_existing) return false;
    }

    for (targets) |target| {
        const fields_value = resolve(
            target,
            plan.pointers[rule.other_pointer_id.?],
        ) orelse return false;
        const fields = switch (fields_value) {
            .object => |object| object,
            else => return false,
        };
        var matched: usize = 0;
        var iterator = fields.iterator();
        while (iterator.next()) |entry| {
            if (!names.contains(entry.key_ptr.*)) continue;
            if (!valueHasKind(entry.value_ptr.*, rule.scalar_kind.?) or
                !boundedNumber(entry.value_ptr.*, rule))
            {
                return false;
            }
            matched += 1;
        }
        if (matched != names.count()) return false;
    }
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

fn arraySorted(
    value: std.json.Value,
    key_pointer: ?Pointer,
) bool {
    const items = switch (value) {
        .array => |array| array.items,
        else => return false,
    };
    if (items.len < 2) return true;
    for (items[1..], 1..) |item, index| {
        const left = if (key_pointer) |pointer|
            resolve(items[index - 1], pointer) orelse return false
        else
            items[index - 1];
        const right = if (key_pointer) |pointer|
            resolve(item, pointer) orelse return false
        else
            item;
        const order = valueOrder(left, right);
        if (key_pointer != null) {
            if (order != .lt) return false;
        } else if (order == .gt) {
            return false;
        }
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

fn keyedUniqueSources(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
    rule: CompiledRule,
) !bool {
    var seen: std.AutoHashMapUnmanaged([32]u8, std.json.Value) = .empty;
    defer seen.deinit(allocator);
    var item_count: usize = 0;
    for (rule.reference_sources) |source| {
        const items = switch (resolve(
            root,
            plan.pointers[source.pointer_id],
        ) orelse return false) {
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
            const key = resolve(
                item,
                plan.pointers[source.reference_pointer_id],
            ) orelse return false;
            const digest = scalarKeyDigest(key) orelse return false;
            const result = try seen.getOrPut(allocator, digest);
            if (result.found_existing) {
                if (valuesEqual(result.value_ptr.*, key)) return false;
                return error.KeyedUniqueDigestCollision;
            }
            result.value_ptr.* = key;
        }
    }
    return true;
}

fn selectedKeyedJoin(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
    rule: CompiledRule,
) !bool {
    const collection = switch (resolve(
        root,
        plan.pointers[rule.pointer_id.?],
    ) orelse return false) {
        .array => |array| array.items,
        else => return false,
    };
    if (collection.len > plan.max_records) return false;
    const selector = resolve(
        root,
        plan.pointers[rule.path_ids[1]],
    ) orelse return false;
    const selector_digest = scalarKeyDigest(selector) orelse return false;
    const expected = resolve(
        root,
        plan.pointers[rule.other_pointer_id.?],
    ) orelse return false;

    var index: std.AutoHashMapUnmanaged([32]u8, std.json.Value) = .empty;
    defer index.deinit(allocator);
    for (collection) |item| {
        const key = resolve(
            item,
            plan.pointers[rule.path_ids[0]],
        ) orelse return false;
        const digest = scalarKeyDigest(key) orelse return false;
        const result = try index.getOrPut(allocator, digest);
        if (result.found_existing) {
            const prior_key = resolve(
                result.value_ptr.*,
                plan.pointers[rule.path_ids[0]],
            ) orelse return false;
            if (valuesEqual(prior_key, key)) return false;
            return error.KeyedJoinDigestCollision;
        }
        result.value_ptr.* = item;
    }
    const selected = index.get(selector_digest) orelse return false;
    const selected_key = resolve(
        selected,
        plan.pointers[rule.path_ids[0]],
    ) orelse return false;
    if (!valuesEqual(selected_key, selector)) {
        return error.KeyedJoinDigestCollision;
    }
    if (rule.children.len != 0 and
        !try itemRulesHold(allocator, plan, rule.children, selected))
    {
        return false;
    }
    const actual = resolve(
        selected,
        plan.pointers[rule.path_ids[2]],
    ) orelse return false;
    return valuesEqual(actual, expected);
}

const CorrespondenceEntry = struct {
    key: std.json.Value,
    value: std.json.Value,
    classified: bool = false,
};

fn predecessorSuccessorHolds(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
    rule: CompiledRule,
) !bool {
    var predecessors: std.AutoHashMapUnmanaged(
        [32]u8,
        CorrespondenceEntry,
    ) = .empty;
    defer predecessors.deinit(allocator);
    var successors: std.AutoHashMapUnmanaged(
        [32]u8,
        CorrespondenceEntry,
    ) = .empty;
    defer successors.deinit(allocator);
    if (!try indexCorrespondenceCollection(
        allocator,
        plan,
        root,
        rule.pointer_id.?,
        rule.path_ids[0],
        &predecessors,
    ) or !try indexCorrespondenceCollection(
        allocator,
        plan,
        root,
        rule.other_pointer_id.?,
        rule.path_ids[1],
        &successors,
    )) return false;

    var reference_count: usize = 0;
    const max_reference_count = plan.max_records *| 8;
    const preserved = try correspondenceReferences(
        plan,
        root,
        rule.path_ids[2],
    ) orelse return false;
    if (!try markPreservedCorrespondence(
        preserved,
        &predecessors,
        &successors,
        &reference_count,
        max_reference_count,
    )) return false;
    const retired = try correspondenceReferences(
        plan,
        root,
        rule.path_ids[3],
    ) orelse return false;
    if (!try markCorrespondenceReferences(
        retired,
        &predecessors,
        &reference_count,
        max_reference_count,
    )) return false;
    const introduced = try correspondenceReferences(
        plan,
        root,
        rule.path_ids[4],
    ) orelse return false;
    if (!try markCorrespondenceReferences(
        introduced,
        &successors,
        &reference_count,
        max_reference_count,
    )) return false;

    const mappings = switch (resolve(
        root,
        plan.pointers[rule.path_ids[5]],
    ) orelse return false) {
        .array => |array| array.items,
        else => return false,
    };
    if (mappings.len > plan.max_records) return false;
    for (mappings) |mapping| {
        const predecessor_refs = switch (resolve(
            mapping,
            plan.pointers[rule.path_ids[6]],
        ) orelse return false) {
            .array => |array| array.items,
            else => return false,
        };
        const successor_refs = switch (resolve(
            mapping,
            plan.pointers[rule.path_ids[7]],
        ) orelse return false) {
            .array => |array| array.items,
            else => return false,
        };
        if (predecessor_refs.len > plan.max_records or
            successor_refs.len > plan.max_records or
            !try markCorrespondenceReferences(
                predecessor_refs,
                &predecessors,
                &reference_count,
                max_reference_count,
            ) or !try markCorrespondenceReferences(
            successor_refs,
            &successors,
            &reference_count,
            max_reference_count,
        )) {
            return false;
        }
    }
    return correspondenceComplete(&predecessors) and
        correspondenceComplete(&successors);
}

fn indexCorrespondenceCollection(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
    collection_pointer_id: u16,
    key_pointer_id: u16,
    index: *std.AutoHashMapUnmanaged([32]u8, CorrespondenceEntry),
) !bool {
    const items = switch (resolve(
        root,
        plan.pointers[collection_pointer_id],
    ) orelse return false) {
        .array => |array| array.items,
        else => return false,
    };
    if (items.len > plan.max_records) return false;
    for (items) |item| {
        const key = resolve(
            item,
            plan.pointers[key_pointer_id],
        ) orelse return false;
        const digest = scalarKeyDigest(key) orelse return false;
        const result = try index.getOrPut(allocator, digest);
        if (result.found_existing) {
            if (valuesEqual(result.value_ptr.key, key)) return false;
            return error.PredecessorSuccessorDigestCollision;
        }
        result.value_ptr.* = .{ .key = key, .value = item };
    }
    return true;
}

fn correspondenceReferences(
    plan: *const Plan,
    root: std.json.Value,
    pointer_id: u16,
) !?[]const std.json.Value {
    return switch (resolve(
        root,
        plan.pointers[pointer_id],
    ) orelse return null) {
        .array => |array| array.items,
        else => null,
    };
}

fn markPreservedCorrespondence(
    references: []const std.json.Value,
    predecessors: *std.AutoHashMapUnmanaged([32]u8, CorrespondenceEntry),
    successors: *std.AutoHashMapUnmanaged([32]u8, CorrespondenceEntry),
    reference_count: *usize,
    max_reference_count: usize,
) !bool {
    for (references) |reference| {
        reference_count.* = std.math.add(
            usize,
            reference_count.*,
            2,
        ) catch return false;
        if (reference_count.* > max_reference_count) return false;
        const digest = scalarKeyDigest(reference) orelse return false;
        const predecessor = predecessors.getPtr(digest) orelse return false;
        const successor = successors.getPtr(digest) orelse return false;
        if (!valuesEqual(predecessor.key, reference) or
            !valuesEqual(successor.key, reference))
        {
            return error.PredecessorSuccessorDigestCollision;
        }
        if (predecessor.classified or successor.classified or
            !valuesEqual(predecessor.value, successor.value))
        {
            return false;
        }
        predecessor.classified = true;
        successor.classified = true;
    }
    return true;
}

fn markCorrespondenceReferences(
    references: []const std.json.Value,
    index: *std.AutoHashMapUnmanaged([32]u8, CorrespondenceEntry),
    reference_count: *usize,
    max_reference_count: usize,
) !bool {
    for (references) |reference| {
        reference_count.* = std.math.add(
            usize,
            reference_count.*,
            1,
        ) catch return false;
        if (reference_count.* > max_reference_count) return false;
        const digest = scalarKeyDigest(reference) orelse return false;
        const entry = index.getPtr(digest) orelse return false;
        if (!valuesEqual(entry.key, reference)) {
            return error.PredecessorSuccessorDigestCollision;
        }
        if (entry.classified) return false;
        entry.classified = true;
    }
    return true;
}

fn correspondenceComplete(
    index: *std.AutoHashMapUnmanaged([32]u8, CorrespondenceEntry),
) bool {
    var iterator = index.valueIterator();
    while (iterator.next()) |entry| {
        if (!entry.classified) return false;
    }
    return true;
}

const FormattedReferenceKey = struct {
    parent: std.json.Value,
    item: std.json.Value,
    value: std.json.Value,
    parts: []const CompiledFormatPart,
};

const ReferenceKey = union(enum) {
    scalar: std.json.Value,
    formatted: FormattedReferenceKey,
};

const ReferenceTarget = struct {
    key: ReferenceKey,
    required: bool,
    ungrouped_required: bool,
    match_allowed: bool,
    referenced: bool = false,
};

const ReferenceCoverageAlias = struct {
    key_digest: [32]u8,
    group: std.json.Value,
};

fn referencesExist(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: CompiledRule,
    source_value: std.json.Value,
    source_root: std.json.Value,
    target_root: std.json.Value,
) !bool {
    var index: std.AutoHashMapUnmanaged([32]u8, ReferenceTarget) = .empty;
    defer index.deinit(allocator);
    var coverage_aliases: std.ArrayList(ReferenceCoverageAlias) = .empty;
    defer coverage_aliases.deinit(allocator);
    if (rule.reference_targets.len == 0) {
        if (!try indexSingleReferenceTargetSet(
            allocator,
            plan,
            rule,
            target_root,
            &index,
            &coverage_aliases,
        )) return false;
    } else if (!try indexReferenceTargetUnion(
        allocator,
        plan,
        rule,
        target_root,
        &index,
        &coverage_aliases,
    )) return false;

    var source_count: usize = 0;
    var reference_count: usize = 0;
    if (rule.reference_sources.len == 0) {
        const source_items = switch (source_value) {
            .array => |array| array.items,
            else => return false,
        };
        source_count = source_items.len;
        if (source_count > plan.max_records or
            !try markReferencesFromItems(
                allocator,
                plan,
                rule,
                source_items,
                rule.other_pointer_id.?,
                &.{},
                &.{},
                &index,
                &reference_count,
            ))
        {
            return false;
        }
    } else {
        for (rule.reference_sources) |source| {
            const items_value = resolve(
                source_root,
                plan.pointers[source.pointer_id],
            ) orelse {
                if (source.optional) continue;
                return false;
            };
            const items = switch (items_value) {
                .array => |array| array.items,
                else => return false,
            };
            if (source.items_pointer_id) |items_pointer_id| {
                for (items) |parent| {
                    const nested_value = resolve(
                        parent,
                        plan.pointers[items_pointer_id],
                    ) orelse return false;
                    const nested_items = switch (nested_value) {
                        .array => |array| array.items,
                        else => return false,
                    };
                    source_count = std.math.add(
                        usize,
                        source_count,
                        nested_items.len,
                    ) catch return false;
                    if (source_count > plan.max_records or
                        !try markReferencesFromItems(
                            allocator,
                            plan,
                            rule,
                            nested_items,
                            source.reference_pointer_id,
                            source.rules,
                            source.format_parts,
                            &index,
                            &reference_count,
                        ))
                    {
                        return false;
                    }
                }
            } else {
                source_count = std.math.add(
                    usize,
                    source_count,
                    items.len,
                ) catch return false;
                if (source_count > plan.max_records or
                    !try markReferencesFromItems(
                        allocator,
                        plan,
                        rule,
                        items,
                        source.reference_pointer_id,
                        source.rules,
                        source.format_parts,
                        &index,
                        &reference_count,
                    ))
                {
                    return false;
                }
            }
        }
    }
    if (rule.total_coverage and
        !try referenceCoverageComplete(
            allocator,
            &index,
            coverage_aliases.items,
        ))
    {
        return false;
    }
    return true;
}

fn markReferencesFromItems(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: CompiledRule,
    source_items: []const std.json.Value,
    reference_pointer_id: u16,
    source_rules: []const CompiledRule,
    format_parts: []const CompiledFormatPart,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    reference_count: *usize,
) !bool {
    for (source_items) |item| {
        if (source_rules.len != 0 and
            !try itemRulesHold(allocator, plan, source_rules, item))
        {
            continue;
        }
        const source_key = if (rule.reject_self_reference)
            resolve(item, plan.pointers[rule.path_ids[1]]) orelse
                return false
        else
            null;
        const references = resolve(
            item,
            plan.pointers[reference_pointer_id],
        ) orelse continue;
        switch (references) {
            .array => |array| for (array.items) |reference| {
                if (rule.ignore_null_references and reference == .null) {
                    continue;
                }
                reference_count.* += 1;
                if (reference_count.* > plan.max_records or
                    !try markSourceReference(
                        plan,
                        index,
                        item,
                        reference,
                        source_key,
                        format_parts,
                    ))
                {
                    return false;
                }
            },
            else => {
                if (rule.ignore_null_references and references == .null) {
                    continue;
                }
                reference_count.* += 1;
                if (reference_count.* > plan.max_records or
                    !try markSourceReference(
                        plan,
                        index,
                        item,
                        references,
                        source_key,
                        format_parts,
                    ))
                {
                    return false;
                }
            },
        }
    }
    return true;
}

fn markSourceReference(
    plan: *const Plan,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    source_item: std.json.Value,
    reference: std.json.Value,
    self_key: ?std.json.Value,
    format_parts: []const CompiledFormatPart,
) !bool {
    if (format_parts.len == 0) {
        return markScalarReference(
            plan,
            index,
            reference,
            self_key,
        );
    }
    if (self_key != null) return false;
    return markReferenceKey(
        plan,
        index,
        .{ .formatted = .{
            .parent = source_item,
            .item = source_item,
            .value = reference,
            .parts = format_parts,
        } },
    );
}

fn indexSingleReferenceTargetSet(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: CompiledRule,
    target_root: std.json.Value,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    coverage_aliases: *std.ArrayList(ReferenceCoverageAlias),
) !bool {
    const target_value = resolve(
        target_root,
        plan.pointers[rule.path_ids[0]],
    ) orelse return false;
    const target_parents = switch (target_value) {
        .array => |array| array.items,
        else => return false,
    };
    if (target_parents.len > plan.max_records) return false;
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
                    index,
                    coverage_aliases,
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
                    index,
                    coverage_aliases,
                ))
            {
                return false;
            }
        }
    }
    return true;
}

fn indexReferenceTargetUnion(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: CompiledRule,
    target_root: std.json.Value,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    coverage_aliases: *std.ArrayList(ReferenceCoverageAlias),
) !bool {
    var target_count: usize = 0;
    for (rule.reference_targets) |target| {
        const parents_value = resolve(
            target_root,
            plan.pointers[target.pointer_id],
        ) orelse {
            if (target.optional) continue;
            return false;
        };
        const parents = switch (parents_value) {
            .array => |array| array.items,
            else => return false,
        };
        for (parents) |parent| {
            if (target.items_pointer_id) |items_pointer_id| {
                const items_value = resolve(
                    parent,
                    plan.pointers[items_pointer_id],
                ) orelse return false;
                const items = switch (items_value) {
                    .array => |array| array.items,
                    else => return false,
                };
                target_count = std.math.add(
                    usize,
                    target_count,
                    items.len,
                ) catch return false;
                if (target_count > plan.max_records) return false;
                for (items) |item| {
                    if (!try indexReferenceTargetSpec(
                        allocator,
                        plan,
                        target,
                        parent,
                        item,
                        index,
                        coverage_aliases,
                    )) return false;
                }
            } else {
                target_count += 1;
                if (target_count > plan.max_records or
                    !try indexReferenceTargetSpec(
                        allocator,
                        plan,
                        target,
                        parent,
                        parent,
                        index,
                        coverage_aliases,
                    ))
                {
                    return false;
                }
            }
        }
    }
    return true;
}

fn indexReferenceTargetSpec(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    target: CompiledReferenceTarget,
    parent: std.json.Value,
    item: std.json.Value,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    coverage_aliases: *std.ArrayList(ReferenceCoverageAlias),
) !bool {
    if (target.rules.len != 0 and
        !try itemRulesHold(allocator, plan, target.rules, item))
    {
        return true;
    }
    const key: ReferenceKey = if (target.key_pointer_id) |pointer_id|
        .{ .scalar = resolve(item, plan.pointers[pointer_id]) orelse
            return false }
    else
        .{ .formatted = .{
            .parent = parent,
            .item = item,
            .value = item,
            .parts = target.format_parts,
        } };
    const required = target.coverage_rules.len == 0 or
        try itemRulesHold(
            allocator,
            plan,
            target.coverage_rules,
            item,
        );
    const coverage_group = if (required)
        if (target.coverage_key_pointer_id) |pointer_id|
            resolve(item, plan.pointers[pointer_id]) orelse return false
        else
            null
    else
        null;
    const match_allowed = target.match_rules.len == 0 or
        try itemRulesHold(
            allocator,
            plan,
            target.match_rules,
            item,
        );
    return indexReferenceKey(
        allocator,
        plan,
        key,
        required,
        coverage_group,
        match_allowed,
        index,
        coverage_aliases,
    );
}

fn indexReferenceTarget(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: CompiledRule,
    item: std.json.Value,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    coverage_aliases: *std.ArrayList(ReferenceCoverageAlias),
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
    const required = rule.coverage_children.len == 0 or
        try itemRulesHold(
            allocator,
            plan,
            rule.coverage_children,
            item,
        );
    return indexReferenceKey(
        allocator,
        plan,
        .{ .scalar = key },
        required,
        null,
        true,
        index,
        coverage_aliases,
    );
}

fn indexReferenceKey(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    key: ReferenceKey,
    required: bool,
    coverage_group: ?std.json.Value,
    match_allowed: bool,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    coverage_aliases: *std.ArrayList(ReferenceCoverageAlias),
) !bool {
    const digest = referenceKeyDigest(plan, key) orelse return false;
    const result = try index.getOrPut(allocator, digest);
    if (result.found_existing) {
        if (!referenceKeysEqual(plan, result.value_ptr.key, key)) {
            return error.ReferenceKeyDigestCollision;
        }
        result.value_ptr.match_allowed =
            result.value_ptr.match_allowed and match_allowed;
    } else {
        result.value_ptr.* = .{
            .key = key,
            .required = required,
            .ungrouped_required = required and coverage_group == null,
            .match_allowed = match_allowed,
        };
    }
    if (required) {
        result.value_ptr.required = true;
        if (coverage_group) |group| {
            if (coverage_aliases.items.len >= plan.max_records) return false;
            try coverage_aliases.append(allocator, .{
                .key_digest = digest,
                .group = group,
            });
        } else {
            result.value_ptr.ungrouped_required = true;
        }
    }
    return true;
}

fn referenceCoverageComplete(
    allocator: std.mem.Allocator,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    coverage_aliases: []const ReferenceCoverageAlias,
) !bool {
    var iterator = index.valueIterator();
    while (iterator.next()) |target| {
        if (target.ungrouped_required and !target.referenced) return false;
    }

    var covered_groups: std.AutoHashMapUnmanaged(
        [32]u8,
        std.json.Value,
    ) = .empty;
    defer covered_groups.deinit(allocator);
    for (coverage_aliases) |alias| {
        const target = index.get(alias.key_digest) orelse
            return error.ReferenceCoverageTargetMissing;
        if (!target.referenced) continue;
        const digest = scalarKeyDigest(alias.group) orelse return false;
        const result = try covered_groups.getOrPut(allocator, digest);
        if (result.found_existing) {
            if (!valuesEqual(result.value_ptr.*, alias.group)) {
                return error.ReferenceCoverageDigestCollision;
            }
        } else {
            result.value_ptr.* = alias.group;
        }
    }
    for (coverage_aliases) |alias| {
        const digest = scalarKeyDigest(alias.group) orelse return false;
        const covered = covered_groups.get(digest) orelse return false;
        if (!valuesEqual(covered, alias.group)) {
            return error.ReferenceCoverageDigestCollision;
        }
    }
    return true;
}

fn markScalarReference(
    plan: *const Plan,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    key: std.json.Value,
    self_key: ?std.json.Value,
) !bool {
    if (self_key) |value| {
        if (valuesEqual(value, key)) return false;
    }
    return markReferenceKey(
        plan,
        index,
        .{ .scalar = key },
    );
}

fn markReferenceKey(
    plan: *const Plan,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    key: ReferenceKey,
) !bool {
    const digest = referenceKeyDigest(plan, key) orelse return false;
    const indexed = index.getPtr(digest) orelse return false;
    if (!referenceKeysEqual(plan, indexed.key, key)) {
        return error.ReferenceKeyDigestCollision;
    }
    if (!indexed.match_allowed) return false;
    indexed.referenced = true;
    return true;
}

fn referenceKeyDigest(
    plan: *const Plan,
    key: ReferenceKey,
) ?[32]u8 {
    return switch (key) {
        .scalar => |value| scalarKeyDigest(value),
        .formatted => |formatted| formattedReferenceDigest(
            plan,
            formatted,
        ),
    };
}

fn referenceKeysEqual(
    plan: *const Plan,
    left: ReferenceKey,
    right: ReferenceKey,
) bool {
    return switch (left) {
        .scalar => |left_value| switch (right) {
            .scalar => |right_value| valuesEqual(left_value, right_value),
            .formatted => |formatted| formattedReferenceMatches(
                plan,
                formatted,
                left_value,
            ),
        },
        .formatted => |left_formatted| switch (right) {
            .scalar => |right_value| formattedReferenceMatches(
                plan,
                left_formatted,
                right_value,
            ),
            .formatted => |right_formatted| blk: {
                var left_buffer: [4096]u8 = undefined;
                var right_buffer: [4096]u8 = undefined;
                const left_text = renderFormattedReference(
                    plan,
                    left_formatted,
                    &left_buffer,
                ) orelse break :blk false;
                const right_text = renderFormattedReference(
                    plan,
                    right_formatted,
                    &right_buffer,
                ) orelse break :blk false;
                break :blk std.mem.eql(u8, left_text, right_text);
            },
        },
    };
}

fn formattedReferenceDigest(
    plan: *const Plan,
    key: FormattedReferenceKey,
) ?[32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("string:");
    var total_bytes: usize = 0;
    for (key.parts) |part| {
        const fragment = formattedReferenceFragment(
            plan,
            key,
            part,
        ) orelse return null;
        total_bytes = std.math.add(
            usize,
            total_bytes,
            fragment.len,
        ) catch return null;
        if (total_bytes > 4096) return null;
        hasher.update(fragment);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn formattedReferenceMatches(
    plan: *const Plan,
    key: FormattedReferenceKey,
    value: std.json.Value,
) bool {
    const text = switch (value) {
        .string => |text| text,
        else => return false,
    };
    var offset: usize = 0;
    for (key.parts) |part| {
        const fragment = formattedReferenceFragment(
            plan,
            key,
            part,
        ) orelse return false;
        const end = std.math.add(
            usize,
            offset,
            fragment.len,
        ) catch return false;
        if (end > text.len or
            !std.mem.eql(u8, text[offset..end], fragment))
        {
            return false;
        }
        offset = end;
    }
    return offset == text.len and offset <= 4096;
}

fn renderFormattedReference(
    plan: *const Plan,
    key: FormattedReferenceKey,
    buffer: *[4096]u8,
) ?[]const u8 {
    var offset: usize = 0;
    for (key.parts) |part| {
        const fragment = formattedReferenceFragment(
            plan,
            key,
            part,
        ) orelse return null;
        const end = std.math.add(
            usize,
            offset,
            fragment.len,
        ) catch return null;
        if (end > buffer.len) return null;
        @memcpy(buffer[offset..end], fragment);
        offset = end;
    }
    return buffer[0..offset];
}

fn formattedReferenceFragment(
    plan: *const Plan,
    key: FormattedReferenceKey,
    part: CompiledFormatPart,
) ?[]const u8 {
    return switch (part) {
        .literal => |literal| literal,
        .parent => |pointer_id| switch (resolve(
            key.parent,
            plan.pointers[pointer_id],
        ) orelse return null) {
            .string => |text| text,
            else => null,
        },
        .item => |pointer_id| switch (resolve(
            key.item,
            plan.pointers[pointer_id],
        ) orelse return null) {
            .string => |text| text,
            else => null,
        },
        .value => switch (key.value) {
            .string => |text| text,
            else => null,
        },
    };
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

fn setSubset(
    left: std.json.Value,
    right: std.json.Value,
    max_records: usize,
) bool {
    const left_items = switch (left) {
        .array => |array| array.items,
        else => return false,
    };
    const right_items = switch (right) {
        .array => |array| array.items,
        else => return false,
    };
    if (left_items.len > max_records or right_items.len > max_records) {
        return false;
    }
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

fn setsDisjoint(
    left: std.json.Value,
    right: std.json.Value,
    max_records: usize,
) bool {
    const left_items = switch (left) {
        .array => |array| array.items,
        else => return false,
    };
    const right_items = switch (right) {
        .array => |array| array.items,
        else => return false,
    };
    if (left_items.len > max_records or right_items.len > max_records) {
        return false;
    }
    for (left_items) |item| {
        for (right_items) |candidate| if (valuesEqual(item, candidate)) return false;
    }
    return true;
}

fn valueMemberOf(
    value: std.json.Value,
    collection: std.json.Value,
    max_records: usize,
) bool {
    if (scalarKeyDigest(value) == null) return false;
    const items = switch (collection) {
        .array => |array| array.items,
        else => return false,
    };
    if (items.len > max_records) return false;
    var found = false;
    for (items) |item| {
        if (scalarKeyDigest(item) == null) return false;
        found = found or valuesEqual(value, item);
    }
    return found;
}

fn pathScopesContain(
    left: std.json.Value,
    right: std.json.Value,
    max_records: usize,
) bool {
    const paths = pathArray(left, max_records) orelse return false;
    const scopes = pathArray(right, max_records) orelse return false;
    for (paths) |path_value| {
        const path = path_value.string;
        var covered = false;
        for (scopes) |scope_value| {
            const scope = scope_value.string;
            if (pathWithinScope(path, scope)) {
                covered = true;
                break;
            }
        }
        if (!covered) return false;
    }
    return true;
}

fn pathScopesDisjoint(
    left: std.json.Value,
    right: std.json.Value,
    max_records: usize,
) bool {
    const left_scopes = pathArray(left, max_records) orelse return false;
    const right_scopes = pathArray(right, max_records) orelse return false;
    for (left_scopes) |left_value| {
        const left_path = left_value.string;
        for (right_scopes) |right_value| {
            const right_path = right_value.string;
            if (pathWithinScope(left_path, right_path) or
                pathWithinScope(right_path, left_path))
            {
                return false;
            }
        }
    }
    return true;
}

fn pathArray(
    value: std.json.Value,
    max_records: usize,
) ?[]const std.json.Value {
    const items = switch (value) {
        .array => |array| array.items,
        else => return null,
    };
    if (items.len > max_records) return null;
    for (items) |item| _ = validRepositoryPath(item) orelse return null;
    return items;
}

fn validRepositoryPath(value: std.json.Value) ?[]const u8 {
    const path = switch (value) {
        .string => |text| text,
        else => return null,
    };
    definition_core.json.repositoryRelativePath(
        path,
        true,
    ) catch return null;
    return path;
}

fn pathWithinScope(path: []const u8, scope: []const u8) bool {
    return std.mem.eql(u8, scope, ".") or
        std.mem.eql(u8, scope, path) or
        (path.len > scope.len and path[scope.len] == '/' and
            std.mem.eql(u8, path[0..scope.len], scope));
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

fn compileRegexPatterns(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) ![]CompiledRegexPattern {
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or values.items.len > 32) {
        return error.RegexPatternCountInvalid;
    }
    const patterns = try allocator.alloc(
        CompiledRegexPattern,
        values.items.len,
    );
    var initialized: usize = 0;
    var total_atoms: usize = 0;
    errdefer {
        for (patterns[0..initialized]) |*pattern| {
            pattern.deinit(allocator);
        }
        allocator.free(patterns);
    }
    for (values.items, 0..) |value, index| {
        patterns[index] = try compileRegexPattern(
            allocator,
            try definition_core.json.string(value),
        );
        initialized += 1;
        total_atoms = std.math.add(
            usize,
            total_atoms,
            patterns[index].atoms.len,
        ) catch return error.RegexStateBoundExceeded;
        if (total_atoms > 256) return error.RegexStateBoundExceeded;
    }
    return patterns;
}

fn compileRegexPattern(
    allocator: std.mem.Allocator,
    pattern: []const u8,
) !CompiledRegexPattern {
    if (pattern.len < 3 or pattern.len > 1024 or
        pattern[0] != '^' or
        pattern[pattern.len - 1] != '$' or
        regexByteEscaped(pattern, pattern.len - 1))
    {
        return error.RegexMustBeAnchored;
    }
    const expression = pattern[1 .. pattern.len - 1];
    var atoms: std.ArrayList(CompiledRegexAtom) = .empty;
    defer atoms.deinit(allocator);
    var index: usize = 0;
    while (index < expression.len) {
        var bytes: [4]u64 = @splat(0);
        switch (expression[index]) {
            '\\' => {
                index += 1;
                if (index >= expression.len) {
                    return error.RegexEscapeInvalid;
                }
                regexByteSet(&bytes, expression[index]);
                index += 1;
            },
            '[' => {
                bytes = try compileRegexClass(expression, &index);
            },
            '.' => {
                bytes = @splat(std.math.maxInt(u64));
                regexByteClear(&bytes, '\n');
                regexByteClear(&bytes, '\r');
                index += 1;
            },
            '*', '+', '?', '{', '}', '(', ')', '|', '^', '$', ']' => {
                return error.RegexConstructUnsupported;
            },
            else => |byte| {
                regexByteSet(&bytes, byte);
                index += 1;
            },
        }
        var quantifier: RegexQuantifier = .one;
        if (index < expression.len) {
            quantifier = switch (expression[index]) {
                '?' => .zero_or_one,
                '*' => .zero_or_more,
                '+' => .one_or_more,
                else => .one,
            };
            if (quantifier != .one) index += 1;
        }
        if (atoms.items.len >= 255) {
            return error.RegexStateBoundExceeded;
        }
        try atoms.append(allocator, .{
            .bytes = bytes,
            .quantifier = quantifier,
        });
    }
    if (atoms.items.len == 0) return error.RegexPatternEmpty;
    return .{ .atoms = try atoms.toOwnedSlice(allocator) };
}

fn compileRegexClass(
    expression: []const u8,
    index: *usize,
) ![4]u64 {
    var bytes: [4]u64 = @splat(0);
    index.* += 1;
    const negated = index.* < expression.len and
        expression[index.*] == '^';
    if (negated) index.* += 1;
    var item_count: usize = 0;
    while (index.* < expression.len and expression[index.*] != ']') {
        const start = try readRegexClassByte(expression, index);
        if (index.* + 1 < expression.len and
            expression[index.*] == '-' and
            expression[index.* + 1] != ']')
        {
            index.* += 1;
            const end = try readRegexClassByte(expression, index);
            if (start > end) return error.RegexClassRangeInvalid;
            var byte: u16 = start;
            while (byte <= end) : (byte += 1) {
                regexByteSet(&bytes, @intCast(byte));
            }
        } else {
            regexByteSet(&bytes, start);
        }
        item_count += 1;
    }
    if (index.* >= expression.len or expression[index.*] != ']') {
        return error.RegexClassUnclosed;
    }
    index.* += 1;
    if (item_count == 0) return error.RegexClassEmpty;
    if (negated) {
        for (&bytes) |*word| word.* = ~word.*;
    }
    return bytes;
}

fn readRegexClassByte(
    expression: []const u8,
    index: *usize,
) !u8 {
    if (index.* >= expression.len or expression[index.*] == ']') {
        return error.RegexClassInvalid;
    }
    if (expression[index.*] == '\\') {
        index.* += 1;
        if (index.* >= expression.len) return error.RegexEscapeInvalid;
    }
    const byte = expression[index.*];
    index.* += 1;
    return byte;
}

fn regexByteEscaped(text: []const u8, index: usize) bool {
    if (index == 0) return false;
    var slash_count: usize = 0;
    var cursor = index;
    while (cursor > 0 and text[cursor - 1] == '\\') {
        slash_count += 1;
        cursor -= 1;
    }
    return slash_count % 2 == 1;
}

fn regexByteSet(bytes: *[4]u64, byte: u8) void {
    const word: usize = @intCast(byte / 64);
    const bit: u6 = @intCast(byte % 64);
    bytes[word] |= @as(u64, 1) << bit;
}

fn regexByteClear(bytes: *[4]u64, byte: u8) void {
    const word: usize = @intCast(byte / 64);
    const bit: u6 = @intCast(byte % 64);
    bytes[word] &= ~(@as(u64, 1) << bit);
}

fn regexByteSetContains(bytes: [4]u64, byte: u8) bool {
    const word: usize = @intCast(byte / 64);
    const bit: u6 = @intCast(byte % 64);
    return bytes[word] & (@as(u64, 1) << bit) != 0;
}

fn regexByteSetEmpty(bytes: [4]u64) bool {
    for (bytes) |word| if (word != 0) return false;
    return true;
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
                "allow_additional",
            },
        );
    } else {
        try definition_core.json.requireExactKeys(
            object,
            &.{
                "op",
                "path",
                "keys",
                "required_keys",
                "optional_keys",
                "allow_additional",
            },
        );
    }
    rule.allow_additional =
        try optionalBoolean(object, "allow_additional") orelse false;
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
        .field_absent,
        .optional_field,
        .scalar_type,
        .bounded_string,
        .regex,
        .sha256,
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
        .path_scope_subset,
        .path_scope_disjoint,
        .member_of,
        .exactly_one,
        .at_least_one,
        .all_rules,
        .any_rules,
        .no_rules,
        .object_values,
        .field_equal,
        .field_not_equal,
        .cross_input_equal,
        .keyed_unique,
        .keyed_join,
        .declared_field_values,
        .reference_exists,
        .implies,
        .predecessor_successor,
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
        .field_absent,
        .optional_field,
        .scalar_type,
        .bounded_string,
        .regex,
        .sha256,
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
        .path_scope_subset,
        .path_scope_disjoint,
        .member_of,
        .field_equal,
        .field_not_equal,
        .exactly_one,
        .at_least_one,
        .keyed_unique,
        .reference_exists,
        .implies,
        .all_rules,
        .any_rules,
        .no_rules,
        .object_values,
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
        \\  "requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object","field-absent","optional-field","scalar-type","enum","safe-identifier","regex","tagged-union","unique","sorted","field-equal","keyed-unique","reference-exists","declared-field-values","disjoint","implies","total-partition","total-mapping","path-format","all","any","none","object-values"]},
        \\  "inputs":{"record":{"codec":"json","max_bytes":4096}},
        \\  "canonicalization":{},
        \\  "shape":{"rules":[
        \\    {"op":"exact-object","path":"","keys":["schema","record_id","status","tags","mirror","items","groups","links","optional_links","containers","selected","checks","more_checks","guards","changes","meta","universe","ordering","accepted","rejected","targets","mappings","declarations","scored"],"allow_additional":true},
        \\    {"op":"field-absent","path":"/forbidden"},
        \\    {"op":"optional-field","path":"/nullable","allow_null":true,"rules":[{"op":"scalar-type","type":"string"}]},
        \\    {"op":"object-values","path":"/meta","rules":[{"op":"tagged-union","path":"","variants":[{"kind":"string","rules":[]},{"kind":"object","rules":[{"op":"exact-object","keys":["value"]},{"op":"scalar-type","path":"/value","type":"string"}]}]}]},
        \\    {"op":"scalar-type","path":"/record_id","type":"string"},
        \\    {"op":"safe-identifier","path":"/record_id","max":64},
        \\    {"op":"regex","path":"/record_id","patterns":["^record-[A-Za-z0-9_.-]+$"],"max":64},
        \\    {"op":"enum","path":"/status","values":["open","closed"]},
        \\    {"op":"unique","path":"/tags"},
        \\    {"op":"sorted","path":"/tags"},
        \\    {"op":"unique","path":"/ordering"},
        \\    {"op":"keyed-unique","path":"/items","key":"/id"},
        \\    {"op":"reference-exists","path":"/links","reference":"/item_refs","target":"/items","key":"/id"},
        \\    {"op":"reference-exists","path":"/links","reference":"/optional_target","target":"/items","key":"/id","ignore_null":true},
        \\    {"op":"reference-exists","path":"/optional_links","reference":"/item_refs","target":"/items","key":"/id"},
        \\    {"op":"reference-exists","path":"/items","reference":"/related_ids","target":"/items","key":"/id","self_reference":"reject"},
        \\    {"op":"reference-exists","path":"/selected","reference":"","target":"/containers","target_items":"/entries","target_rules":[{"op":"enum","path":"/status","values":["active","inactive"]}],"coverage_rules":[{"op":"enum","path":"/status","values":["active"]}],"key":"/id","coverage":"all-targets"},
        \\    {"op":"path-format","path":"/groups","items":"/members","target":"/label","fragments":[{"parent":"/prefix"},{"literal":":"},{"item":"/name"}]},
        \\    {"op":"optional-field","path":"/meta/closure","rules":[{"op":"enum","values":["confirmed"]}]},
        \\    {"op":"all","path":"/items","rules":[
        \\      {"op":"exact-object","keys":["id","kind","state","labels","related_ids"]},
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
        \\    {"op":"implies","if":"/status","equals":"closed","then":"/meta/closure","then_nonempty":true},
        \\    {"op":"implies","if":"/changes","nonempty":true,"then":"/meta/transport"},
        \\    {"op":"reference-exists","path":"/accepted","reference":"","target":"/universe","key":""},
        \\    {"op":"reference-exists","path":"/ordering","reference":"","target":"/universe","key":"","coverage":"all-targets"},
        \\    {"op":"reference-exists","sources":[{"path":"/checks","reference":""},{"path":"/more_checks","reference":""},{"path":"/groups","items":"/members","reference":"/target_id"},{"path":"/missing_checks","reference":"","optional":true}],"targets":[
        \\      {"path":"/items","key":"/id"},
        \\      {"path":"/groups","items":"/members","fragments":[{"parent":"/prefix"},{"literal":":"},{"item":"/name"}]},
        \\      {"path":"/missing_groups","key":"","optional":true}
        \\    ]},
        \\    {"op":"reference-exists","sources":[
        \\      {"path":"/guards","reference":"/ids","rules":[{"op":"enum","path":"/mode","values":["active"]}],"fragments":[{"literal":"id:"},{"value":true}]},
        \\      {"path":"/guards","reference":"/kinds","rules":[{"op":"enum","path":"/mode","values":["active"]}],"fragments":[{"literal":"kind:"},{"value":true}]}
        \\    ],"targets":[
        \\      {"path":"/items","fragments":[{"literal":"id:"},{"item":"/id"}],"coverage_key":"/id"},
        \\      {"path":"/items","fragments":[{"literal":"kind:"},{"item":"/kind"}],"coverage_key":"/id","match_rules":[{"op":"enum","path":"/state","values":["ready"]}]}
        \\    ],"coverage":"all-targets"},
        \\    {"op":"declared-field-values","path":"/scored","object":"/values","declarations":"/declarations","declaration_paths":["/increase","/decrease"],"type":"integer","min":0,"max":100},
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
        "{\"schema\":\"example/v1\",\"record_id\":\"record-1\",\"status\":\"open\",\"tags\":[\"a\",\"b\"],\"mirror\":\"open\",\"items\":[{\"id\":\"item-1\",\"kind\":\"shared\",\"state\":\"ready\",\"labels\":[\"a\"],\"related_ids\":[\"item-2\"]},{\"id\":\"item-2\",\"kind\":\"shared\",\"state\":\"ready\",\"labels\":[\"b\"],\"related_ids\":[]}],\"groups\":[{\"prefix\":\"g\",\"members\":[{\"name\":\"one\",\"label\":\"g:one\",\"target_id\":\"item-1\"}]}],\"links\":[{\"item_refs\":[\"item-1\",\"item-2\"],\"optional_target\":null,\"expected\":[\"a\"],\"prohibited\":[\"b\"]}],\"optional_links\":[{}],\"containers\":[{\"entries\":[{\"id\":\"nested-1\",\"status\":\"active\"},{\"id\":\"nested-2\",\"status\":\"inactive\"},{\"id\":\"nested-3\",\"status\":\"disabled\"}]}],\"selected\":[\"nested-1\"],\"checks\":[\"item-1\",\"g:one\"],\"more_checks\":[\"item-2\"],\"guards\":[{\"mode\":\"active\",\"ids\":[],\"kinds\":[\"shared\"]},{\"mode\":\"inactive\",\"ids\":[],\"kinds\":[\"missing\"]}],\"changes\":[],\"meta\":{},\"universe\":[\"a\",\"b\"],\"ordering\":[\"a\",\"b\"],\"accepted\":[\"a\"],\"rejected\":[\"b\"],\"targets\":[\"x\",\"y\"],\"mappings\":[{\"from\":\"a\",\"to\":\"x\"},{\"from\":\"b\",\"to\":\"y\"}],\"declarations\":[{\"increase\":\"speed\"},{\"decrease\":\"cost\"}],\"scored\":[{\"values\":{\"speed\":90,\"cost\":10,\"undeclared\":999}}],\"nullable\":null,\"extension\":\"preserved\"}";
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

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "wrapper.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/wrapper","owner":"example","imports":[{"id":"example/record","path":"artifact.json"}],"requires":{"abi":"ledger-artifact-abi/v1","operators":["definition-ref"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"definition-ref","path":"","definition":"example/record"}]},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":10,"max_output_bytes":4096,"max_diagnostics":16,"max_reducer_states":16}}
        ,
    });
    var wrapper_closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "wrapper.json",
        .{},
    );
    defer wrapper_closure.deinit(std.testing.allocator);
    var wrapper_definition = try definition.compile(
        std.testing.allocator,
        &wrapper_closure,
        "wrapper.json",
    );
    defer wrapper_definition.deinit(std.testing.allocator);
    var wrapper_plan = try compile(
        std.testing.allocator,
        &wrapper_definition,
    );
    defer wrapper_plan.deinit(std.testing.allocator);
    var wrapper_encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        8 * 1024 * 1024,
    );
    defer wrapper_encoder.deinit();
    try encodeCache(&wrapper_plan, &wrapper_encoder);
    const wrapper_payload = try wrapper_encoder.toOwnedSlice();
    defer std.testing.allocator.free(wrapper_payload);
    var wrapper_decoder =
        definition_core.cache.Decoder.init(wrapper_payload);
    var cached_wrapper = try decodeCache(
        std.testing.allocator,
        &wrapper_decoder,
    );
    defer cached_wrapper.deinit(std.testing.allocator);
    try wrapper_decoder.finish();
    try validateCachePlan(&cached_wrapper, &wrapper_definition);
    var wrapped_valid = try validate(
        std.testing.allocator,
        &wrapper_definition,
        &cached_wrapper,
        &.{.{ .name = "record", .bytes = valid_bytes }},
    );
    defer wrapped_valid.deinit(std.testing.allocator);
    try std.testing.expect(wrapped_valid.valid);

    const invalid_pattern_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"record_id\":\"record-1\"",
        "\"record_id\":\"other-1\"",
    );
    defer std.testing.allocator.free(invalid_pattern_bytes);
    var invalid_pattern = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = invalid_pattern_bytes,
        }},
    );
    defer invalid_pattern.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_pattern.valid);
    var wrapped_invalid = try validate(
        std.testing.allocator,
        &wrapper_definition,
        &cached_wrapper,
        &.{.{
            .name = "record",
            .bytes = invalid_pattern_bytes,
        }},
    );
    defer wrapped_invalid.deinit(std.testing.allocator);
    try std.testing.expect(!wrapped_invalid.valid);

    const forbidden_field_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"extension\":\"preserved\"",
        "\"extension\":\"preserved\",\"forbidden\":true",
    );
    defer std.testing.allocator.free(forbidden_field_bytes);
    var forbidden_field = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = forbidden_field_bytes,
        }},
    );
    defer forbidden_field.deinit(std.testing.allocator);
    try std.testing.expect(!forbidden_field.valid);

    const missing_declared_field_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"speed\":90,\"cost\":10",
        "\"speed\":90",
    );
    defer std.testing.allocator.free(missing_declared_field_bytes);
    var missing_declared_field = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = missing_declared_field_bytes,
        }},
    );
    defer missing_declared_field.deinit(std.testing.allocator);
    try std.testing.expect(!missing_declared_field.valid);

    const duplicate_declaration_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "{\"increase\":\"speed\"},{\"decrease\":\"cost\"}",
        "{\"increase\":\"speed\"},{\"decrease\":\"speed\"}",
    );
    defer std.testing.allocator.free(duplicate_declaration_bytes);
    var duplicate_declaration = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = duplicate_declaration_bytes,
        }},
    );
    defer duplicate_declaration.deinit(std.testing.allocator);
    try std.testing.expect(!duplicate_declaration.valid);

    const out_of_bounds_declared_field_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"speed\":90,\"cost\":10",
        "\"speed\":101,\"cost\":10",
    );
    defer std.testing.allocator.free(out_of_bounds_declared_field_bytes);
    var out_of_bounds_declared_field = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = out_of_bounds_declared_field_bytes,
        }},
    );
    defer out_of_bounds_declared_field.deinit(std.testing.allocator);
    try std.testing.expect(!out_of_bounds_declared_field.valid);

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

    const invalid_object_value_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"meta\":{}",
        "\"meta\":{\"entry\":{\"value\":1}}",
    );
    defer std.testing.allocator.free(invalid_object_value_bytes);
    var invalid_object_value = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = invalid_object_value_bytes,
        }},
    );
    defer invalid_object_value.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_object_value.valid);

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
        "\"selected\":[\"nested-3\"]",
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

    const invalid_union_reference_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"checks\":[\"item-1\",\"g:one\"]",
        "\"checks\":[\"item-1\",\"g:missing\"]",
    );
    defer std.testing.allocator.free(invalid_union_reference_bytes);
    var invalid_union_reference = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = invalid_union_reference_bytes,
        }},
    );
    defer invalid_union_reference.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_union_reference.valid);

    const incomplete_alias_coverage_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"guards\":[{\"mode\":\"active\",\"ids\":[],\"kinds\":[\"shared\"]},{\"mode\":\"inactive\",\"ids\":[],\"kinds\":[\"missing\"]}]",
        "\"guards\":[{\"mode\":\"active\",\"ids\":[\"item-1\"],\"kinds\":[]},{\"mode\":\"inactive\",\"ids\":[],\"kinds\":[\"shared\"]}]",
    );
    defer std.testing.allocator.free(incomplete_alias_coverage_bytes);
    var incomplete_alias_coverage = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = incomplete_alias_coverage_bytes,
        }},
    );
    defer incomplete_alias_coverage.deinit(std.testing.allocator);
    try std.testing.expect(!incomplete_alias_coverage.valid);

    const disallowed_match_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"id\":\"item-2\",\"kind\":\"shared\",\"state\":\"ready\"",
        "\"id\":\"item-2\",\"kind\":\"shared\",\"state\":\"blocked\"",
    );
    defer std.testing.allocator.free(disallowed_match_bytes);
    var disallowed_match = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = disallowed_match_bytes,
        }},
    );
    defer disallowed_match.deinit(std.testing.allocator);
    try std.testing.expect(!disallowed_match.valid);

    const missing_implication_target_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        "\"changes\":[]",
        "\"changes\":[\"changed\"]",
    );
    defer std.testing.allocator.free(missing_implication_target_bytes);
    var missing_implication_target = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = missing_implication_target_bytes,
        }},
    );
    defer missing_implication_target.deinit(std.testing.allocator);
    try std.testing.expect(!missing_implication_target.valid);

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
            .bytes = "{\"schema\":\"example/v1\",\"record_id\":\"bad id\",\"status\":\"closed\",\"tags\":[\"b\",\"a\",\"a\"],\"mirror\":\"open\",\"items\":[{\"id\":\"item-1\",\"labels\":[1,\"forbidden\"],\"related_ids\":[]},{\"id\":\"item-1\",\"labels\":[],\"related_ids\":[]}],\"groups\":[{\"prefix\":\"g\",\"members\":[{\"name\":\"one\",\"label\":\"g:one\"}]}],\"links\":[{\"item_refs\":[\"missing\"],\"optional_target\":null,\"expected\":[\"same\"],\"prohibited\":[\"same\"]}],\"optional_links\":[{}],\"containers\":[{\"entries\":[{\"id\":\"nested-1\",\"status\":\"active\"},{\"id\":\"nested-3\",\"status\":\"disabled\"}]}],\"selected\":[\"nested-1\"],\"checks\":[\"item-1\",\"g:one\"],\"more_checks\":[\"item-2\"],\"changes\":[],\"meta\":{},\"universe\":[\"a\",\"b\"],\"ordering\":[\"a\",\"b\"],\"accepted\":[\"a\",\"b\"],\"rejected\":[\"b\"],\"targets\":[\"x\",\"y\"],\"mappings\":[{\"from\":\"a\",\"to\":\"x\"},{\"from\":\"a\",\"to\":\"y\"}],\"declarations\":[{\"increase\":\"speed\"},{\"decrease\":\"cost\"}],\"scored\":[{\"values\":{\"speed\":90,\"cost\":10}}],\"extra\":true}",
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

test "compiled path scope comparisons preserve hierarchy and bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/path-scopes","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object","member-of","path-scope-disjoint","path-scope-subset"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","path":"","keys":["allowed","choices","paths","prohibited","selection"]}]},"constraints":[{"op":"path-scope-subset","left":"/paths","right":"/allowed"},{"op":"path-scope-disjoint","left":"/paths","right":"/prohibited"},{"op":"member-of","left":"/selection","right":"/choices"}],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
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

    const valid_cases = [_][]const u8{
        "{\"allowed\":[\"src\"],\"choices\":[\"inspect\",\"edit\"],\"paths\":[\"src/file.zig\"],\"prohibited\":[\"docs\"],\"selection\":\"inspect\"}",
        "{\"allowed\":[\".\"],\"choices\":[1,2],\"paths\":[\"src\"],\"prohibited\":[],\"selection\":2}",
        "{\"allowed\":[\"src\",\"tests\"],\"choices\":[true],\"paths\":[],\"prohibited\":[\".git\"],\"selection\":true}",
    };
    for (valid_cases) |bytes| {
        var result = try validate(
            std.testing.allocator,
            &definition_plan,
            &cached,
            &.{.{ .name = "record", .bytes = bytes }},
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.valid);
    }

    const invalid_cases = [_][]const u8{
        "{\"allowed\":[\"src\"],\"choices\":[\"inspect\"],\"paths\":[\"vendor/file\"],\"prohibited\":[],\"selection\":\"inspect\"}",
        "{\"allowed\":[\"src\"],\"choices\":[\"inspect\"],\"paths\":[\"src\"],\"prohibited\":[\"src/generated\"],\"selection\":\"inspect\"}",
        "{\"allowed\":[\"src\",\"bad/../scope\"],\"choices\":[\"inspect\"],\"paths\":[\"src/file\"],\"prohibited\":[],\"selection\":\"inspect\"}",
        "{\"allowed\":[\".\"],\"choices\":[\"inspect\"],\"paths\":[\"a\",\"b\",\"c\",\"d\",\"e\"],\"prohibited\":[],\"selection\":\"inspect\"}",
        "{\"allowed\":[\"src\"],\"choices\":[\"inspect\"],\"paths\":[\"src/file\"],\"prohibited\":[],\"selection\":\"edit\"}",
        "{\"allowed\":[\"src\"],\"choices\":[\"inspect\",{}],\"paths\":[\"src/file\"],\"prohibited\":[],\"selection\":\"inspect\"}",
    };
    for (invalid_cases) |bytes| {
        var result = try validate(
            std.testing.allocator,
            &definition_plan,
            &cached,
            &.{.{ .name = "record", .bytes = bytes }},
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.valid);
    }
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        validateForAllocationFailure,
        .{
            &definition_plan,
            &plan,
            valid_cases[0],
        },
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

test "compiled correspondence rules bind selected values and total successor partitions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/correspondence","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["at-least-one","enum","exactly-one","keyed-join","predecessor-successor","sorted"]},"inputs":{"record":{"codec":"json","max_bytes":8192}},"canonicalization":{},"shape":{"rules":[
        \\{"op":"sorted","path":"/successors","key":"/id"},
        \\{"op":"exactly-one","path":"/candidates","rules":[{"op":"enum","path":"/status","values":["selected"]}]},
        \\{"op":"at-least-one","path":"/candidates","rules":[{"op":"enum","path":"/derivation","values":["independent"]}]}
        \\]},"constraints":[
        \\{"op":"keyed-join","collection":"/candidates","key":"/id","selector":"/selected_id","value":"/factors","equals":"/surface","rules":[{"op":"enum","path":"/status","values":["selected"]}]},
        \\{"op":"predecessor-successor","predecessor":"/predecessors","predecessor_key":"/id","successor":"/successors","successor_key":"/id","preserved":"/preserved","retired":"/retired","introduced":"/introduced","mappings":"/mappings","mapping_predecessors":"/from","mapping_successors":"/to"}
        \\],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":8192,"max_store_bytes":8192,"max_records":32,"max_output_bytes":8192,"max_diagnostics":16,"max_reducer_states":1}}
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
        1024 * 1024,
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

    const valid_bytes =
        \\{"candidates":[{"derivation":"independent","factors":["factor-a"],"id":"candidate-a","status":"selected"},{"derivation":"relative","factors":["factor-b"],"id":"candidate-b","status":"dominated"}],"introduced":["factor-c"],"mappings":[],"predecessors":[{"id":"factor-a","value":"same"},{"id":"factor-b","value":"old"}],"preserved":["factor-a"],"retired":["factor-b"],"selected_id":"candidate-a","successors":[{"id":"factor-a","value":"same"},{"id":"factor-c","value":"new"}],"surface":["factor-a"]}
    ;
    var valid = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{ .name = "record", .bytes = valid_bytes }},
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(valid.valid);

    const invalid_cases = [_][]const u8{
        "{\"candidates\":[{\"derivation\":\"independent\",\"factors\":[\"factor-a\"],\"id\":\"candidate-a\",\"status\":\"selected\"},{\"derivation\":\"relative\",\"factors\":[\"factor-b\"],\"id\":\"candidate-b\",\"status\":\"selected\"}],\"introduced\":[\"factor-c\"],\"mappings\":[],\"predecessors\":[{\"id\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-b\",\"value\":\"old\"}],\"preserved\":[\"factor-a\"],\"retired\":[\"factor-b\"],\"selected_id\":\"candidate-a\",\"successors\":[{\"id\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-c\",\"value\":\"new\"}],\"surface\":[\"factor-a\"]}",
        "{\"candidates\":[{\"derivation\":\"independent\",\"factors\":[\"factor-a\"],\"id\":\"candidate-a\",\"status\":\"selected\"},{\"derivation\":\"relative\",\"factors\":[\"factor-b\"],\"id\":\"candidate-b\",\"status\":\"dominated\"}],\"introduced\":[\"factor-c\"],\"mappings\":[],\"predecessors\":[{\"id\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-b\",\"value\":\"old\"}],\"preserved\":[\"factor-a\"],\"retired\":[\"factor-b\"],\"selected_id\":\"candidate-b\",\"successors\":[{\"id\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-c\",\"value\":\"new\"}],\"surface\":[\"factor-b\"]}",
        "{\"candidates\":[{\"derivation\":\"independent\",\"factors\":[\"factor-a\"],\"id\":\"candidate-a\",\"status\":\"selected\"},{\"derivation\":\"relative\",\"factors\":[\"factor-b\"],\"id\":\"candidate-b\",\"status\":\"dominated\"}],\"introduced\":[\"factor-c\"],\"mappings\":[],\"predecessors\":[{\"id\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-b\",\"value\":\"old\"}],\"preserved\":[\"factor-a\"],\"retired\":[\"factor-b\"],\"selected_id\":\"candidate-a\",\"successors\":[{\"id\":\"factor-a\",\"value\":\"changed\"},{\"id\":\"factor-c\",\"value\":\"new\"}],\"surface\":[\"factor-a\"]}",
        "{\"candidates\":[{\"derivation\":\"independent\",\"factors\":[\"factor-a\"],\"id\":\"candidate-a\",\"status\":\"selected\"},{\"derivation\":\"relative\",\"factors\":[\"factor-b\"],\"id\":\"candidate-b\",\"status\":\"dominated\"}],\"introduced\":[],\"mappings\":[],\"predecessors\":[{\"id\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-b\",\"value\":\"old\"}],\"preserved\":[\"factor-a\"],\"retired\":[\"factor-b\"],\"selected_id\":\"candidate-a\",\"successors\":[{\"id\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-c\",\"value\":\"new\"}],\"surface\":[\"factor-a\"]}",
        "{\"candidates\":[{\"derivation\":\"independent\",\"factors\":[\"factor-a\"],\"id\":\"candidate-a\",\"status\":\"selected\"},{\"derivation\":\"relative\",\"factors\":[\"factor-b\"],\"id\":\"candidate-b\",\"status\":\"dominated\"}],\"introduced\":[\"factor-c\"],\"mappings\":[],\"predecessors\":[{\"id\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-b\",\"value\":\"old\"}],\"preserved\":[\"factor-a\"],\"retired\":[\"factor-b\"],\"selected_id\":\"candidate-a\",\"successors\":[{\"id\":\"factor-c\",\"value\":\"new\"},{\"id\":\"factor-a\",\"value\":\"same\"}],\"surface\":[\"factor-a\"]}",
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

test "compiled namespace uniqueness and nested reference coverage survive cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/namespaces","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["keyed-unique","reference-exists","tagged-union"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[
        \\{"op":"keyed-unique","sources":[{"path":"/first","key":"/id"},{"path":"/second","key":"/name"}]},
        \\{"op":"tagged-union","path":"","tag":"/mode","variants":[{"value":"expanded","rules":[{"op":"reference-exists","path":"/introduced","reference":"","target":"/additions","key":"/id","coverage":"all-targets"}]},{"value":"plain","rules":[]}]}
        \\]},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":16,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
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
        1024 * 1024,
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

    const cases = [_]struct { bytes: []const u8, valid: bool }{
        .{
            .bytes = "{\"additions\":[{\"id\":\"factor-new\"}],\"first\":[{\"id\":\"proof-1\"}],\"introduced\":[\"factor-new\"],\"mode\":\"expanded\",\"second\":[{\"name\":\"retirement-1\"}]}",
            .valid = true,
        },
        .{
            .bytes = "{\"additions\":[{\"id\":\"factor-new\"}],\"first\":[{\"id\":\"proof-1\"}],\"introduced\":[\"factor-new\"],\"mode\":\"expanded\",\"second\":[{\"name\":\"proof-1\"}]}",
            .valid = false,
        },
        .{
            .bytes = "{\"additions\":[],\"first\":[{\"id\":\"proof-1\"}],\"introduced\":[\"factor-new\"],\"mode\":\"expanded\",\"second\":[{\"name\":\"retirement-1\"}]}",
            .valid = false,
        },
    };
    for (cases) |case| {
        var result = try validate(
            std.testing.allocator,
            &definition_plan,
            &cached,
            &.{.{ .name = "record", .bytes = case.bytes }},
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.valid, result.valid);
    }
}

test "compiled sha256 validates canonical documents and framed streams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/digests","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["object-values","sha256"]},"inputs":{"record":{"codec":"json","max_bytes":8192}},"canonicalization":{},"shape":{"rules":[
        \\{"op":"sha256","path":"/review","mode":"canonical-json-null","field":"/contract_digest","null":"/contract_digest","max_bytes":4096},
        \\{"op":"object-values","path":"/manifests","rules":[{"op":"sha256","mode":"framed-items","field":"/contract_digest","items":"/resources","prefix":"lens-contract/v1\u0000","fragments":[{"item":"/path"},{"literal":"\u0000"},{"item":"/digest"},{"literal":"\u0000"}],"max_bytes":4096}]},
        \\{"op":"sha256","path":"/campaign","mode":"framed-fields","field":"/campaign_id","prefix":"campaign/v1\u0000","fragments":[{"parent":"/goal_id"},{"literal":"\u0000"},{"parent":"/construction_ref"},{"literal":"\u0000"},{"parent":"/subject_digest"},{"literal":"\u0000"},{"parent":"/review_contract_digest"}],"max_bytes":4096}
        \\]},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":8192,"max_store_bytes":8192,"max_records":16,"max_output_bytes":8192,"max_diagnostics":8,"max_reducer_states":1}}
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

    const review_basis =
        "{\"contract_digest\":null,\"contract_id\":\"review\",\"schema\":\"review/v1\"}";
    const review_digest =
        try definition_core.canonical_json.digestBytesAlloc(
            std.testing.allocator,
            review_basis,
        );
    defer std.testing.allocator.free(review_digest);
    const resource_digest =
        "sha256:1111111111111111111111111111111111111111111111111111111111111111";
    var framed_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    framed_hasher.update("lens-contract/v1\x00");
    framed_hasher.update("lens.md");
    framed_hasher.update("\x00");
    framed_hasher.update(resource_digest);
    framed_hasher.update("\x00");
    var framed_raw: [32]u8 = undefined;
    framed_hasher.final(&framed_raw);
    const framed_hex = std.fmt.bytesToHex(framed_raw, .lower);
    const framed_digest = try std.fmt.allocPrint(
        std.testing.allocator,
        "sha256:{s}",
        .{framed_hex},
    );
    defer std.testing.allocator.free(framed_digest);
    var field_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    field_hasher.update("campaign/v1\x00");
    field_hasher.update("goal-1");
    field_hasher.update("\x00");
    field_hasher.update("construction-1");
    field_hasher.update("\x00");
    field_hasher.update("subject-1");
    field_hasher.update("\x00");
    field_hasher.update(resource_digest);
    var field_raw: [32]u8 = undefined;
    field_hasher.final(&field_raw);
    const field_hex = std.fmt.bytesToHex(field_raw, .lower);
    const field_digest = try std.fmt.allocPrint(
        std.testing.allocator,
        "sha256:{s}",
        .{field_hex},
    );
    defer std.testing.allocator.free(field_digest);
    const valid_bytes = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"campaign\":{{\"campaign_id\":\"{s}\",\"construction_ref\":\"construction-1\",\"goal_id\":\"goal-1\",\"review_contract_digest\":\"{s}\",\"subject_digest\":\"subject-1\"}},\"manifests\":{{\"standard\":{{\"contract_digest\":\"{s}\",\"resources\":[{{\"digest\":\"{s}\",\"path\":\"lens.md\"}}]}}}},\"review\":{{\"contract_digest\":\"{s}\",\"contract_id\":\"review\",\"schema\":\"review/v1\"}}}}",
        .{
            field_digest,
            resource_digest,
            framed_digest,
            resource_digest,
            review_digest,
        },
    );
    defer std.testing.allocator.free(valid_bytes);

    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
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

    var valid = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{ .name = "record", .bytes = valid_bytes }},
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(valid.valid);

    const wrong_digest =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const invalid_review_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        review_digest,
        wrong_digest,
    );
    defer std.testing.allocator.free(invalid_review_bytes);
    var invalid_review = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{ .name = "record", .bytes = invalid_review_bytes }},
    );
    defer invalid_review.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_review.valid);

    const invalid_manifest_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        framed_digest,
        wrong_digest,
    );
    defer std.testing.allocator.free(invalid_manifest_bytes);
    var invalid_manifest = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{ .name = "record", .bytes = invalid_manifest_bytes }},
    );
    defer invalid_manifest.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_manifest.valid);
    const invalid_campaign_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_bytes,
        field_digest,
        wrong_digest,
    );
    defer std.testing.allocator.free(invalid_campaign_bytes);
    var invalid_campaign = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{ .name = "record", .bytes = invalid_campaign_bytes }},
    );
    defer invalid_campaign.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_campaign.valid);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        validateForAllocationFailure,
        .{ &definition_plan, &plan, valid_bytes },
    );
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

test "definition references execute imported cross-record constraints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "record.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/record-set","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object","keyed-unique"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","path":"","keys":["left","right"]}]},"constraints":[{"op":"keyed-unique","sources":[{"path":"/left","key":"/id"},{"path":"/right","key":"/id"}]}],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":8,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "wrapper.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/wrapper","owner":"example","imports":[{"id":"example/record-set","path":"record.json"}],"requires":{"abi":"ledger-artifact-abi/v1","operators":["definition-ref","exact-object"]},"inputs":{"wrapper":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","path":"","keys":["record"]},{"op":"definition-ref","path":"/record","definition":"example/record-set"}]},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":8,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "wrapper.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "wrapper.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var plan = try compile(std.testing.allocator, &definition_plan);
    defer plan.deinit(std.testing.allocator);

    var valid = try validate(
        std.testing.allocator,
        &definition_plan,
        &plan,
        &.{.{
            .name = "wrapper",
            .bytes = "{\"record\":{\"left\":[{\"id\":\"a\"}],\"right\":[{\"id\":\"b\"}]}}",
        }},
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(valid.valid);

    var duplicate = try validate(
        std.testing.allocator,
        &definition_plan,
        &plan,
        &.{.{
            .name = "wrapper",
            .bytes = "{\"record\":{\"left\":[{\"id\":\"a\"}],\"right\":[{\"id\":\"a\"}]}}",
        }},
    );
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expect(!duplicate.valid);
}

test "embedded validation compares borrowed event and retained state values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/embedded","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["cross-input-equal","implies"]},"inputs":{"event":{"codec":"json","required":false,"max_bytes":4096},"state":{"codec":"json","required":false,"max_bytes":4096}},"canonicalization":{},"shape":{},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":8192,"max_store_bytes":8192,"max_records":8,"max_output_bytes":8192,"max_diagnostics":8,"max_reducer_states":2}}
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
    var rules = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\[
        \\  {"op":"cross-input-equal","input":"event","left_input":"event","left":"/goal_id","right_input":"state","right":"/goal_id"},
        \\  {"op":"implies","input":"event","if":"/effect","equals":"edit","then_input":"state","then":"/mutation_allowed","then_equals":true}
        \\]
    ,
        .{},
    );
    defer rules.deinit();
    var plan = try compileEmbedded(
        std.testing.allocator,
        &definition_plan,
        definition_plan.inputs,
        rules.value,
        8192,
        8,
        8,
    );
    defer plan.deinit(std.testing.allocator);
    var event = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"effect\":\"edit\",\"goal_id\":\"goal-1\"}",
        .{},
    );
    defer event.deinit();
    var matching = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"goal_id\":\"goal-1\",\"mutation_allowed\":true}",
        .{},
    );
    defer matching.deinit();
    var valid = try executeValues(
        std.testing.allocator,
        &plan,
        &.{
            .{ .name = "event", .value = event.value },
            .{ .name = "state", .value = matching.value },
        },
    );
    defer valid.deinit();
    try std.testing.expect(valid.isValid());

    var stale = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"goal_id\":\"goal-2\",\"mutation_allowed\":true}",
        .{},
    );
    defer stale.deinit();
    var invalid = try executeValues(
        std.testing.allocator,
        &plan,
        &.{
            .{ .name = "event", .value = event.value },
            .{ .name = "state", .value = stale.value },
        },
    );
    defer invalid.deinit();
    try std.testing.expect(!invalid.isValid());

    var denied = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"goal_id\":\"goal-1\",\"mutation_allowed\":false}",
        .{},
    );
    defer denied.deinit();
    var denied_edit = try executeValues(
        std.testing.allocator,
        &plan,
        &.{
            .{ .name = "event", .value = event.value },
            .{ .name = "state", .value = denied.value },
        },
    );
    defer denied_edit.deinit();
    try std.testing.expect(!denied_edit.isValid());

    var inspection = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"effect\":\"inspect\",\"goal_id\":\"goal-1\"}",
        .{},
    );
    defer inspection.deinit();
    var allowed_inspection = try executeValues(
        std.testing.allocator,
        &plan,
        &.{
            .{ .name = "event", .value = inspection.value },
            .{ .name = "state", .value = denied.value },
        },
    );
    defer allowed_inspection.deinit();
    try std.testing.expect(allowed_inspection.isValid());
}
