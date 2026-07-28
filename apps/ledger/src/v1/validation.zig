const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");

const max_regex_patterns: usize = 32;
const max_regex_atoms_per_pattern: usize = 255;
const max_regex_total_atoms: usize =
    max_regex_patterns * max_regex_atoms_per_pattern;
const max_regex_subject_bytes: usize = 16 * 1024 * 1024;
const max_sha256_subject_bytes: usize = 16 * 1024 * 1024;
const max_cache_rule_tasks: usize = 128 * 65_535;
const max_value_equality_pairs: usize = 1_000_000;

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
    number: []u8,
    boolean: bool,
    null,

    fn deinit(self: *EnumScalar, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |text| allocator.free(text),
            .number => |text| allocator.free(text),
            else => {},
        }
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

const RegexRepetition = struct {
    minimum: usize,
    maximum: usize,
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
    canonical_json,
};

const imported_self_input = std.math.maxInt(u16);

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
    singleton: bool = false,
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
    min_number: ?EnumScalar = null,
    max_number: ?EnumScalar = null,
    identifier_style: IdentifierStyle = .portable,
    allow_root: bool = true,
    case_insensitive: bool = false,
    allow_additional: bool = false,
    allow_null: bool = false,
    allow_bare_digest: bool = false,
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
        if (self.min_number) |*value| value.deinit(allocator);
        if (self.max_number) |*value| value.deinit(allocator);
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
    root_shared_prefixes: []u16,
    max_root_pointer_depth: u16,
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
        allocator.free(self.root_shared_prefixes);
        self.* = undefined;
    }
};

const RootTraversal = struct {
    shared_prefixes: []u16,
    max_depth: u16,

    fn deinit(self: RootTraversal, allocator: std.mem.Allocator) void {
        allocator.free(self.shared_prefixes);
    }
};

fn compileRootTraversal(
    allocator: std.mem.Allocator,
    pointers: []const Pointer,
    rules: []const CompiledRule,
) !RootTraversal {
    const shared_prefixes = try allocator.alloc(u16, rules.len);
    errdefer allocator.free(shared_prefixes);
    var prior_input_index: ?u8 = null;
    var prior_pointer_id: ?u16 = null;
    var largest_depth: usize = 0;
    for (rules, 0..) |rule, index| {
        const depth = if (rule.pointer_id) |pointer_id|
            pointers[pointer_id].segments.len
        else
            0;
        if (depth > 1024) return error.JsonPointerTooDeep;
        largest_depth = @max(largest_depth, depth);
        shared_prefixes[index] =
            if (prior_input_index == rule.input_index)
                if (prior_pointer_id) |prior_id|
                    if (rule.pointer_id) |pointer_id|
                        @intCast(commonPointerDepth(
                            pointers[prior_id],
                            pointers[pointer_id],
                        ))
                    else
                        0
                else
                    0
            else
                0;
        if (rule.operator == .implies and rule.children.len != 0) {
            prior_input_index = null;
            prior_pointer_id = null;
        } else {
            prior_input_index = rule.input_index;
            prior_pointer_id = rule.pointer_id;
        }
    }
    return .{
        .shared_prefixes = shared_prefixes,
        .max_depth = @intCast(largest_depth),
    };
}

const Builder = struct {
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    inputs: []const definition.Input,
    pointers: std.ArrayList(Pointer) = .empty,
    rules: std.ArrayList(CompiledRule) = .empty,
    item_rule_count: usize = 0,
    conditional_depth: usize = 0,
    inherited_input_index: ?u8 = null,

    fn initRule(
        self: *Builder,
        operator: definition.Operator,
        input_index: u8,
        pointer_id: ?u16,
    ) !CompiledRule {
        return .{
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
    }

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

    fn compileRawRule(self: *Builder, value: std.json.Value) anyerror!void {
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

    fn compileConditionalRules(
        self: *Builder,
        raw: std.json.Value,
        input_index: u8,
    ) anyerror![]CompiledRule {
        const values = try definition_core.json.array(raw);
        if (values.items.len == 0 or values.items.len > 64 or
            self.conditional_depth >= 16)
        {
            return error.InvalidConditionalRuleCount;
        }
        const start = self.rules.items.len;
        errdefer {
            for (self.rules.items[start..]) |*rule| {
                rule.deinit(self.allocator);
            }
            self.rules.shrinkRetainingCapacity(start);
        }
        self.conditional_depth += 1;
        defer self.conditional_depth -= 1;
        const previous_input_index = self.inherited_input_index;
        self.inherited_input_index = input_index;
        defer self.inherited_input_index = previous_input_index;
        for (values.items) |value| try self.compileRawRule(value);
        const count = self.rules.items.len - start;
        if (count != values.items.len) {
            return error.UnsupportedConditionalRule;
        }
        const rules = try self.allocator.alloc(CompiledRule, count);
        @memcpy(rules, self.rules.items[start..]);
        self.rules.shrinkRetainingCapacity(start);
        return rules;
    }

    fn compileRule(self: *Builder, source: definition.Rule) anyerror!void {
        if (!isValidationOperator(source.operator)) return;
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            source.canonical_config,
            .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
                .parse_numbers = false,
            },
        );
        defer parsed.deinit();
        const object = try definition_core.json.object(parsed.value);
        const input_index = if (object.get("input")) |raw_input|
            try self.inputIndex(try definition_core.json.string(raw_input))
        else if (self.inherited_input_index) |inherited|
            inherited
        else if (self.inputs.len == 1)
            0
        else
            return error.AmbiguousRuleInput;

        var rule = try self.initRule(
            source.operator,
            input_index,
            source.pointer_id,
        );
        errdefer rule.deinit(self.allocator);

        try self.compileRootRuleOperator(source, object, input_index, &rule);
        try self.rules.append(self.allocator, rule);
    }

    fn compileRootRuleOperator(
        self: *Builder,
        source: definition.Rule,
        object: std.json.ObjectMap,
        input_index: u8,
        rule: *CompiledRule,
    ) anyerror!void {
        if (isPrimitiveRootOperator(source.operator)) {
            return self.compilePrimitiveRootRule(object, rule);
        }
        if (isRelationalRootOperator(source.operator)) {
            return self.compileRelationalRootRule(
                source,
                object,
                input_index,
                rule,
            );
        }
        return self.compileNestedProtocolRootRule(
            source,
            object,
            input_index,
            rule,
        );
    }

    fn compilePrimitiveRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) anyerror!void {
        switch (rule.operator) {
            .exact_object => try compileExactObjectRule(
                self.allocator,
                object,
                true,
                rule,
            ),
            .field_absent => try requireRootPathOnly(object),
            .forbidden_object_keys => try compileForbiddenObjectKeysRule(
                self.allocator,
                object,
                true,
                rule,
            ),
            .optional_field => try self.compileOptionalRootRule(object, rule),
            .scalar_type => rule.scalar_kind = try JsonKind.parse(
                try definition_core.json.requiredString(object, "type"),
            ),
            .bounded_array,
            .bounded_object,
            => try compileCountBoundRootRule(object, rule),
            .bounded_string => try compileStringBoundRootRule(object, rule),
            .regex => try compileRegexRootRule(self.allocator, object, rule),
            .digest => try compileDigestRule(object, true, rule),
            .timestamp => try requireRootPathOnly(object),
            .sha256 => try self.compileSha256Rule(object, true, rule),
            .safe_identifier => try compileIdentifierRootRule(object, rule),
            .safe_relative_path => try compileRelativePathRule(
                self.allocator,
                object,
                rule,
            ),
            .sorted => try self.compileSortedRootRule(object, rule),
            .bounded_number => try compileNumberBoundRootRule(
                self.allocator,
                object,
                rule,
            ),
            .enum_value => rule.values = try parseEnumValues(
                self.allocator,
                try definition_core.json.field(object, "values"),
            ),
            else => unreachable,
        }
    }

    fn compileRelationalRootRule(
        self: *Builder,
        source: definition.Rule,
        object: std.json.ObjectMap,
        input_index: u8,
        rule: *CompiledRule,
    ) anyerror!void {
        switch (source.operator) {
            .set_equality,
            .subset,
            .superset,
            .disjoint,
            .path_scope_subset,
            .path_scope_disjoint,
            .member_of,
            .not_member_of,
            .field_equal,
            .field_not_equal,
            => try self.compileComparisonRootRule(
                object,
                input_index,
                source.pointer_id,
                rule,
            ),
            .declared_field_values => try self.compileDeclaredValuesRootRule(
                object,
                source.pointer_id,
                rule,
            ),
            .cross_input_equal => try self.compileCrossInputRootRule(
                object,
                rule,
            ),
            .implies => try self.compileImplication(
                object,
                input_index,
                0,
                false,
                rule,
            ),
            .total_partition => try self.compilePartitionRootRule(object, rule),
            .total_mapping => try self.compileMappingRootRule(object, rule),
            .path_format => try self.compilePathFormat(object, rule),
            .exactly_one, .at_least_one => try self.compileCountRootRule(
                object,
                input_index,
                source.pointer_id,
                rule,
            ),
            .keyed_join => try self.compileKeyedJoinRootRule(
                object,
                input_index,
                rule,
            ),
            .predecessor_successor => try self.compileCorrespondenceRootRule(
                object,
                rule,
            ),
            else => unreachable,
        }
    }

    fn compileNestedProtocolRootRule(
        self: *Builder,
        source: definition.Rule,
        object: std.json.ObjectMap,
        input_index: u8,
        rule: *CompiledRule,
    ) anyerror!void {
        switch (source.operator) {
            .one_of,
            .all_rules,
            .any_rules,
            .no_rules,
            .object_values,
            => try self.compileNestedRootRule(object, input_index, rule),
            .tagged_union => try self.compileTaggedUnion(
                object,
                input_index,
                0,
                true,
                rule,
            ),
            .definition_ref => try self.compileDefinitionRef(
                object,
                true,
                source.import_index,
                rule,
            ),
            .keyed_unique => try self.compileKeyedUniqueRootRule(
                object,
                source.pointer_id,
                rule,
            ),
            .reference_exists => try self.compileReferenceRootRule(
                object,
                input_index,
                source.pointer_id,
                rule,
            ),
            else => {},
        }
    }

    fn compileOptionalRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) anyerror!void {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "input", "path", "rules", "allow_null" },
        );
        try definition_core.json.requireFields(object, &.{ "op", "path" });
        if (object.get("rules")) |raw_rules| {
            rule.children = try self.compileItemRules(
                raw_rules,
                rule.input_index,
                0,
            );
        }
        rule.allow_null =
            try optionalBoolean(object, "allow_null") orelse false;
    }

    fn compileSortedRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) !void {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "input", "path", "key" },
        );
        try definition_core.json.requireFields(object, &.{ "op", "path" });
        if (object.get("key")) |raw_key| {
            rule.other_pointer_id = try self.internPointer(
                try definition_core.json.string(raw_key),
            );
        }
    }

    fn compileComparisonRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        scope_pointer_id: ?u16,
        rule: *CompiledRule,
    ) !void {
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
    }

    fn compileDeclaredValuesRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        source_pointer_id: ?u16,
        rule: *CompiledRule,
    ) !void {
        try requireDeclaredValuesKeys(object);
        if (source_pointer_id == null) {
            return error.DeclaredFieldCollectionMissing;
        }
        rule.other_pointer_id = try self.internPointer(
            try definition_core.json.requiredString(object, "object"),
        );
        const declaration_pointer_id = try self.internPointer(
            try definition_core.json.requiredString(object, "declarations"),
        );
        const declaration_paths = try self.parsePaths(
            try definition_core.json.field(object, "declaration_paths"),
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
        try compileNumberBoundRootRule(self.allocator, object, rule);
    }

    fn compileCrossInputRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) !void {
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
    }

    fn compilePartitionRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) !void {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "input", "universe", "parts" },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "op", "universe", "parts" },
        );
        rule.pointer_id = try self.internPointer(
            try definition_core.json.requiredString(object, "universe"),
        );
        rule.path_ids = try self.parsePaths(
            try definition_core.json.field(object, "parts"),
        );
        if (rule.path_ids.len < 2) {
            return error.TotalPartitionRequiresMultipleParts;
        }
    }

    fn compileMappingRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) !void {
        try requireMappingKeys(object);
        rule.pointer_id = try self.internPointer(
            try definition_core.json.requiredString(object, "source"),
        );
        rule.other_pointer_id = try self.internPointer(
            try definition_core.json.requiredString(object, "target"),
        );
        rule.path_ids = try self.allocator.alloc(u16, 3);
        const names = [_][]const u8{ "mapping", "from", "to" };
        for (names, 0..) |name, index| {
            rule.path_ids[index] = try self.internPointer(
                try definition_core.json.requiredString(object, name),
            );
        }
    }

    fn compileCountRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        source_pointer_id: ?u16,
        rule: *CompiledRule,
    ) anyerror!void {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "input", "path", "paths", "rules" },
        );
        const has_path = object.get("path") != null;
        if (has_path == (object.get("paths") != null)) {
            return error.ConflictingCountRuleTargets;
        }
        if (has_path) {
            if (source_pointer_id == null) {
                return error.CountRuleCollectionMissing;
            }
            rule.children = try self.compileItemRules(
                try definition_core.json.field(object, "rules"),
                input_index,
                0,
            );
            return;
        }
        rule.path_ids = try self.parsePaths(
            try definition_core.json.field(object, "paths"),
        );
        if (object.get("rules")) |raw_rules| {
            rule.children = try self.compileItemRules(
                raw_rules,
                input_index,
                0,
            );
        }
    }

    fn compileKeyedJoinRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        rule: *CompiledRule,
    ) anyerror!void {
        try requireKeyedJoinKeys(object);
        rule.pointer_id = try self.internPointer(
            try definition_core.json.requiredString(object, "collection"),
        );
        rule.other_pointer_id = try self.internPointer(
            try definition_core.json.requiredString(object, "equals"),
        );
        rule.path_ids = try self.allocator.alloc(u16, 3);
        const names = [_][]const u8{ "key", "selector", "value" };
        for (names, 0..) |name, index| {
            rule.path_ids[index] = try self.internPointer(
                try definition_core.json.requiredString(object, name),
            );
        }
        if (object.get("rules")) |raw_rules| {
            rule.children = try self.compileItemRules(
                raw_rules,
                input_index,
                0,
            );
        }
    }

    fn compileCorrespondenceRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) !void {
        try requireCorrespondenceKeys(object);
        rule.pointer_id = try self.internPointer(
            try definition_core.json.requiredString(object, "predecessor"),
        );
        rule.other_pointer_id = try self.internPointer(
            try definition_core.json.requiredString(object, "successor"),
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
        rule.path_ids = try self.allocator.alloc(u16, pointer_names.len);
        for (pointer_names, 0..) |name, index| {
            rule.path_ids[index] = try self.internPointer(
                try definition_core.json.requiredString(object, name),
            );
        }
    }

    fn compileNestedRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        rule: *CompiledRule,
    ) anyerror!void {
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
    }

    fn compileKeyedUniqueRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        source_pointer_id: ?u16,
        rule: *CompiledRule,
    ) anyerror!void {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "input", "path", "key", "sources" },
        );
        const has_path = object.get("path") != null;
        if (has_path == (object.get("sources") != null)) {
            return error.ConflictingKeyedUniqueSources;
        }
        if (has_path) {
            try definition_core.json.requireFields(
                object,
                &.{ "op", "path", "key" },
            );
            if (source_pointer_id == null) {
                return error.KeyedUniqueCollectionMissing;
            }
            rule.other_pointer_id = try self.internPointer(
                try definition_core.json.requiredString(object, "key"),
            );
            return;
        }
        if (object.get("key") != null) {
            return error.KeyedUniqueKeyUnexpected;
        }
        rule.pointer_id = null;
        rule.reference_sources = try self.compileKeySources(
            try definition_core.json.field(object, "sources"),
        );
    }

    fn compileReferenceRootRule(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        source_pointer_id: ?u16,
        rule: *CompiledRule,
    ) anyerror!void {
        try requireReferenceRootKeys(object);
        rule.other_input_index = if (object.get("target_input")) |raw|
            try self.inputIndex(try definition_core.json.string(raw))
        else
            input_index;
        try self.compileReferenceRootSources(
            object,
            input_index,
            source_pointer_id,
            rule,
        );
        try self.compileReferenceRootTargets(object, rule);
        try compileReferenceRootPolicies(object, rule);
    }

    fn compileReferenceRootSources(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        source_pointer_id: ?u16,
        rule: *CompiledRule,
    ) anyerror!void {
        if (object.get("sources")) |raw_sources| {
            if (object.get("path") != null or
                object.get("reference") != null)
            {
                return error.ConflictingReferenceSources;
            }
            rule.reference_sources = try self.compileReferenceSources(
                raw_sources,
                input_index,
            );
            return;
        }
        try definition_core.json.requireFields(
            object,
            &.{ "path", "reference" },
        );
        if (source_pointer_id == null) {
            return error.ReferenceCollectionMissing;
        }
        rule.other_pointer_id = try self.internPointer(
            try definition_core.json.string(
                try definition_core.json.field(object, "reference"),
            ),
        );
    }

    fn compileReferenceRootTargets(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) anyerror!void {
        if (object.get("targets")) |raw_targets| {
            if (hasSingleReferenceTargetFields(object)) {
                return error.ConflictingReferenceTargets;
            }
            rule.reference_targets = try self.compileReferenceTargets(
                raw_targets,
                rule.other_input_index.?,
            );
            return;
        }
        try definition_core.json.requireFields(
            object,
            &.{ "target", "key" },
        );
        const target_items = try self.optionalPointer(object, "target_items");
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
        if (target_items) |pointer_id| rule.path_ids[2] = pointer_id;
        try self.compileReferenceRootTargetRules(object, rule);
    }

    fn compileReferenceRootTargetRules(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) anyerror!void {
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
            sources[index] = try self.compileReferenceSource(
                item,
                input_index,
            );
            initialized += 1;
        }
        return sources;
    }

    fn compileReferenceSource(
        self: *Builder,
        raw: std.json.Value,
        input_index: u8,
    ) anyerror!CompiledReferenceSource {
        const object = try definition_core.json.object(raw);
        try definition_core.json.requireExactKeys(
            object,
            &.{
                "path",
                "items",
                "reference",
                "fragments",
                "rules",
                "optional",
                "singleton",
            },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "path", "reference" },
        );
        var source: CompiledReferenceSource = .{
            .pointer_id = try self.internPointer(
                try definition_core.json.string(
                    try definition_core.json.field(object, "path"),
                ),
            ),
            .items_pointer_id = try self.optionalPointer(object, "items"),
            .reference_pointer_id = try self.internPointer(
                try definition_core.json.string(
                    try definition_core.json.field(object, "reference"),
                ),
            ),
            .optional = try optionalBoolean(object, "optional") orelse false,
            .rules = try self.allocator.alloc(CompiledRule, 0),
            .format_parts = try self.allocator.alloc(CompiledFormatPart, 0),
        };
        errdefer source.deinit(self.allocator);
        if (object.get("rules")) |raw_rules| {
            source.rules = try self.compileItemRules(
                raw_rules,
                input_index,
                0,
            );
        }
        source.singleton =
            try optionalBoolean(object, "singleton") orelse false;
        if (source.singleton and source.items_pointer_id != null) {
            return error.ReferenceSourceModeConflict;
        }
        if (object.get("fragments")) |raw_fragments| {
            source.format_parts = try self.compileFormatParts(
                raw_fragments,
                true,
            );
        }
        return source;
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
            targets[index] = try self.compileReferenceTarget(
                item,
                input_index,
            );
            initialized += 1;
        }
        return targets;
    }

    fn compileReferenceTarget(
        self: *Builder,
        raw: std.json.Value,
        input_index: u8,
    ) anyerror!CompiledReferenceTarget {
        const object = try definition_core.json.object(raw);
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
        if ((object.get("key") == null) == (object.get("fragments") == null)) {
            return error.ReferenceTargetKeyInvalid;
        }
        var target = try self.initReferenceTarget(object);
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
        return target;
    }

    fn initReferenceTarget(
        self: *Builder,
        object: std.json.ObjectMap,
    ) !CompiledReferenceTarget {
        return .{
            .pointer_id = try self.internPointer(
                try definition_core.json.requiredString(object, "path"),
            ),
            .optional = try optionalBoolean(object, "optional") orelse false,
            .items_pointer_id = try self.optionalPointer(object, "items"),
            .key_pointer_id = try self.optionalPointer(object, "key"),
            .coverage_key_pointer_id = try self.optionalPointer(
                object,
                "coverage_key",
            ),
            .rules = try self.allocator.alloc(CompiledRule, 0),
            .match_rules = try self.allocator.alloc(CompiledRule, 0),
            .coverage_rules = try self.allocator.alloc(CompiledRule, 0),
            .format_parts = try self.allocator.alloc(CompiledFormatPart, 0),
        };
    }

    fn optionalPointer(
        self: *Builder,
        object: std.json.ObjectMap,
        name: []const u8,
    ) !?u16 {
        const raw = object.get(name) orelse return null;
        return @as(
            ?u16,
            try self.internPointer(try definition_core.json.string(raw)),
        );
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

    fn compileImplication(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        depth: usize,
        item_mode: bool,
        rule: *CompiledRule,
    ) anyerror!void {
        try requireImplicationKeys(object, item_mode);
        try definition_core.json.requireFields(object, &.{ "op", "if" });
        rule.pointer_id = try self.internPointer(
            try definition_core.json.requiredString(object, "if"),
        );
        const conditional_rules = object.get("rules");
        try self.compileImplicationConsequence(
            object,
            input_index,
            depth,
            item_mode,
            conditional_rules,
            rule,
        );
        try compileImplicationPredicates(
            self.allocator,
            object,
            conditional_rules != null,
            rule,
        );
    }

    fn requireImplicationKeys(
        object: std.json.ObjectMap,
        item_mode: bool,
    ) !void {
        if (item_mode) {
            try definition_core.json.requireExactKeys(
                object,
                &.{
                    "op",
                    "if",
                    "equals",
                    "empty",
                    "nonempty",
                    "then",
                    "then_equals",
                    "then_nonempty",
                    "rules",
                },
            );
        } else {
            try definition_core.json.requireExactKeys(
                object,
                &.{
                    "op",
                    "input",
                    "if",
                    "equals",
                    "empty",
                    "nonempty",
                    "then",
                    "then_input",
                    "then_equals",
                    "then_nonempty",
                    "rules",
                },
            );
        }
    }

    fn compileImplicationConsequence(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        depth: usize,
        item_mode: bool,
        conditional_rules: ?std.json.Value,
        rule: *CompiledRule,
    ) anyerror!void {
        const consequent_path = object.get("then");
        if ((consequent_path == null) == (conditional_rules == null)) {
            return error.ImplicationConsequenceAmbiguous;
        }
        if (consequent_path) |raw_consequent| {
            rule.other_pointer_id = try self.internPointer(
                try definition_core.json.string(raw_consequent),
            );
            rule.other_input_index = if (!item_mode and
                object.get("then_input") != null)
                try self.inputIndex(
                    try definition_core.json.string(
                        object.get("then_input").?,
                    ),
                )
            else
                input_index;
        } else {
            if (object.get("then_input") != null or
                object.get("then_equals") != null or
                object.get("then_nonempty") != null)
            {
                return error.ConditionalRulesHaveScalarConsequence;
            }
            rule.children = if (item_mode)
                try self.compileItemRules(
                    conditional_rules.?,
                    input_index,
                    depth + 1,
                )
            else
                try self.compileConditionalRules(
                    conditional_rules.?,
                    input_index,
                );
        }
    }

    fn compileImplicationPredicates(
        allocator: std.mem.Allocator,
        object: std.json.ObjectMap,
        has_conditional_rules: bool,
        rule: *CompiledRule,
    ) !void {
        const condition_equals = object.get("equals");
        const condition_empty =
            try optionalBoolean(object, "empty") orelse false;
        const condition_nonempty =
            try optionalBoolean(object, "nonempty") orelse false;
        const consequent_equals = object.get("then_equals");
        rule.then_nonempty =
            try optionalBoolean(object, "then_nonempty") orelse false;
        if (@as(usize, @intFromBool(condition_equals != null)) +
            @as(usize, @intFromBool(condition_empty)) +
            @as(usize, @intFromBool(condition_nonempty)) > 1)
        {
            return error.ConflictingImplicationPredicates;
        }
        if (consequent_equals != null and rule.then_nonempty) {
            return error.ConflictingImplicationConsequences;
        }
        if (has_conditional_rules and consequent_equals != null) {
            return error.ConditionalRulesHaveScalarConsequence;
        }
        if (consequent_equals != null and
            condition_equals == null and
            !condition_empty and
            !condition_nonempty)
        {
            return error.ImplicationConsequenceRequiresPredicate;
        }
        const value_count: usize =
            @as(usize, @intFromBool(condition_equals != null)) +
            @as(usize, @intFromBool(consequent_equals != null));
        if (value_count != 0) {
            rule.values = try implicationValues(
                allocator,
                condition_equals,
                consequent_equals,
                value_count,
            );
        }
        if (condition_nonempty) rule.min_count = 1;
        if (condition_empty) rule.max_count = 0;
    }

    fn implicationValues(
        allocator: std.mem.Allocator,
        condition_equals: ?std.json.Value,
        consequent_equals: ?std.json.Value,
        value_count: usize,
    ) ![]EnumScalar {
        const values = try allocator.alloc(EnumScalar, value_count);
        var value_index: usize = 0;
        errdefer {
            for (values[0..value_index]) |*value| {
                value.deinit(allocator);
            }
            allocator.free(values);
        }
        if (condition_equals) |value| {
            values[value_index] = try parseEnumScalar(allocator, value);
            value_index += 1;
        }
        if (consequent_equals) |value| {
            values[value_index] = try parseEnumScalar(allocator, value);
            value_index += 1;
        }
        return values;
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
        if (!isItemOperator(operator)) {
            return error.UnsupportedItemOperator;
        }
        if (object.contains("input")) return error.ItemRuleInputForbidden;
        const pointer_id = if (object.get("path")) |raw|
            try self.internPointer(try definition_core.json.string(raw))
        else
            null;
        var rule = try self.initRule(operator, input_index, pointer_id);
        errdefer rule.deinit(self.allocator);
        if (isPrimitiveItemOperator(operator)) {
            try self.compilePrimitiveItemRule(object, depth, &rule);
        } else {
            try self.compileCompositeItemRule(
                object,
                input_index,
                depth,
                &rule,
            );
        }
        return rule;
    }

    fn compilePrimitiveItemRule(
        self: *Builder,
        object: std.json.ObjectMap,
        depth: usize,
        rule: *CompiledRule,
    ) anyerror!void {
        switch (rule.operator) {
            .exact_object => try compileExactObjectRule(
                self.allocator,
                object,
                false,
                rule,
            ),
            .optional_field => try self.compileOptionalItemRule(
                object,
                depth,
                rule,
            ),
            .required_field, .field_absent, .timestamp, .unique => {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "op", "path" },
                );
            },
            .digest => try compileDigestRule(object, false, rule),
            .forbidden_object_keys => try compileForbiddenObjectKeysRule(
                self.allocator,
                object,
                false,
                rule,
            ),
            .sorted => try self.compileSortedItemRule(object, rule),
            .scalar_type => try compileScalarItemRule(object, rule),
            .bounded_array,
            .bounded_object,
            => try compileCountBoundItemRule(object, rule),
            .bounded_string => try compileStringBoundItemRule(object, rule),
            .regex => try compileRegexItemRule(
                self.allocator,
                object,
                rule,
            ),
            .sha256 => try self.compileSha256Rule(object, false, rule),
            .safe_identifier => try compileIdentifierItemRule(object, rule),
            .safe_relative_path => try compileRelativePathRule(
                self.allocator,
                object,
                rule,
            ),
            .bounded_number => try compileNumberBoundItemRule(
                self.allocator,
                object,
                rule,
            ),
            .enum_value => try compileEnumItemRule(
                self.allocator,
                object,
                rule,
            ),
            else => unreachable,
        }
    }

    fn compileCompositeItemRule(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        depth: usize,
        rule: *CompiledRule,
    ) anyerror!void {
        switch (rule.operator) {
            .set_equality,
            .subset,
            .superset,
            .disjoint,
            .path_scope_subset,
            .path_scope_disjoint,
            .member_of,
            .not_member_of,
            .field_equal,
            .field_not_equal,
            => try self.compileComparisonItemRule(object, input_index, rule),
            .exactly_one,
            .at_least_one,
            => try self.compileCountItemRule(object, input_index, depth, rule),
            .keyed_unique => try self.compileKeyedUniqueItemRule(object, rule),
            .reference_exists => try self.compileReferenceItemRule(
                object,
                input_index,
                depth,
                rule,
            ),
            .implies => try self.compileImplication(
                object,
                input_index,
                depth,
                true,
                rule,
            ),
            .one_of,
            .all_rules,
            .any_rules,
            .no_rules,
            .object_values,
            => try self.compileNestedItemRule(object, input_index, depth, rule),
            .tagged_union => try self.compileTaggedUnion(
                object,
                input_index,
                depth,
                false,
                rule,
            ),
            .definition_ref => try self.compileDefinitionRef(
                object,
                false,
                null,
                rule,
            ),
            else => unreachable,
        }
    }

    fn compileOptionalItemRule(
        self: *Builder,
        object: std.json.ObjectMap,
        depth: usize,
        rule: *CompiledRule,
    ) anyerror!void {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "path", "rules", "allow_null" },
        );
        try definition_core.json.requireFields(object, &.{ "op", "path" });
        if (object.get("rules")) |raw_rules| {
            rule.children = try self.compileItemRules(
                raw_rules,
                rule.input_index,
                depth + 1,
            );
        }
        rule.allow_null =
            try optionalBoolean(object, "allow_null") orelse false;
    }

    fn compileSortedItemRule(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) !void {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "path", "key" },
        );
        if (object.get("key")) |raw_key| {
            rule.other_pointer_id = try self.internPointer(
                try definition_core.json.string(raw_key),
            );
        }
    }

    fn compileComparisonItemRule(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        rule: *CompiledRule,
    ) !void {
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
    }

    fn compileCountItemRule(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        depth: usize,
        rule: *CompiledRule,
    ) anyerror!void {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "path", "paths", "rules" },
        );
        const has_path = object.get("path") != null;
        if (has_path == (object.get("paths") != null)) {
            return error.ConflictingCountRuleTargets;
        }
        if (has_path) {
            if (rule.pointer_id == null) {
                return error.CountRuleCollectionMissing;
            }
            rule.children = try self.compileItemRules(
                try definition_core.json.field(object, "rules"),
                input_index,
                depth + 1,
            );
            return;
        }
        rule.path_ids = try self.parsePaths(
            try definition_core.json.field(object, "paths"),
        );
        if (object.get("rules")) |raw_rules| {
            rule.children = try self.compileItemRules(
                raw_rules,
                input_index,
                depth + 1,
            );
        }
    }

    fn compileKeyedUniqueItemRule(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) !void {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "path", "key" },
        );
        if (rule.pointer_id == null) {
            return error.KeyedUniqueCollectionMissing;
        }
        rule.other_pointer_id = try self.internPointer(
            try definition_core.json.requiredString(object, "key"),
        );
    }

    fn compileReferenceItemRule(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        depth: usize,
        rule: *CompiledRule,
    ) anyerror!void {
        try requireReferenceItemKeys(object);
        if (rule.pointer_id == null) {
            return error.ReferenceCollectionMissing;
        }
        rule.other_input_index = input_index;
        rule.other_pointer_id = try self.internPointer(
            try definition_core.json.string(
                try definition_core.json.field(object, "reference"),
            ),
        );
        try self.compileReferenceItemTarget(
            object,
            input_index,
            depth,
            rule,
        );
        try compileReferencePolicies(object, rule.pointer_id.?, rule);
    }

    fn compileReferenceItemTarget(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        depth: usize,
        rule: *CompiledRule,
    ) anyerror!void {
        const target_items = try self.optionalPointer(object, "target_items");
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
        if (target_items) |pointer_id| rule.path_ids[2] = pointer_id;
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
    }

    fn compileNestedItemRule(
        self: *Builder,
        object: std.json.ObjectMap,
        input_index: u8,
        depth: usize,
        rule: *CompiledRule,
    ) anyerror!void {
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
    }

    fn compileDefinitionRef(
        self: *Builder,
        object: std.json.ObjectMap,
        allow_input: bool,
        expected_import_index: ?u16,
        rule: *CompiledRule,
    ) anyerror!void {
        if (allow_input) {
            try definition_core.json.requireExactKeys(
                object,
                &.{ "op", "input", "path", "definition", "inputs" },
            );
        } else {
            try definition_core.json.requireExactKeys(
                object,
                &.{ "op", "path", "definition", "inputs" },
            );
        }
        try definition_core.json.requireFields(
            object,
            &.{ "op", "path", "definition" },
        );
        const definition_id = try definition_core.json.requiredString(
            object,
            "definition",
        );
        const import_index = try findImportedDefinition(
            self.definition_plan,
            definition_id,
        );
        if (expected_import_index) |expected| {
            if (expected != import_index) {
                return error.ImportedDefinitionIndexMismatch;
            }
        }
        if (import_index >= self.definition_plan.imports.len) {
            return error.ImportedDefinitionIndexInvalid;
        }
        const imported_definition =
            &self.definition_plan.imports[import_index];
        if (!std.mem.eql(
            u8,
            imported_definition.id,
            definition_id,
        )) return error.ImportedDefinitionIdMismatch;
        for (imported_definition.inputs) |input| {
            if (input.codec != .json or !input.required) {
                return error.ImportedDefinitionNotReusable;
            }
        }
        const bindings = try self.compileImportedInputBindings(
            object.get("inputs"),
            imported_definition.inputs,
        );
        self.allocator.free(rule.path_ids);
        rule.path_ids = bindings;
        rule.imported_plan = try self.compileImportedPlan(imported_definition);
        rule.import_index = import_index;
    }

    fn compileImportedInputBindings(
        self: *Builder,
        raw: ?std.json.Value,
        imported_inputs: []const definition.Input,
    ) ![]u16 {
        if (raw == null) {
            if (imported_inputs.len != 1) {
                return error.ImportedDefinitionInputBindingsMissing;
            }
            const bindings = try self.allocator.alloc(u16, 1);
            bindings[0] = imported_self_input;
            return bindings;
        }
        const object = try definition_core.json.object(raw.?);
        if (object.count() != imported_inputs.len) {
            return error.ImportedDefinitionInputBindingsMismatch;
        }
        const bindings = try self.allocator.alloc(
            u16,
            imported_inputs.len,
        );
        errdefer self.allocator.free(bindings);
        var self_count: usize = 0;
        for (imported_inputs, 0..) |input, index| {
            const binding = try definition_core.json.requiredString(
                object,
                input.name,
            );
            if (std.mem.eql(u8, binding, "$self")) {
                bindings[index] = imported_self_input;
                self_count += 1;
            } else {
                bindings[index] = try self.inputIndex(binding);
            }
        }
        if (self_count != 1) {
            return error.ImportedDefinitionSelfBindingInvalid;
        }
        return bindings;
    }

    fn compileImportedPlan(
        self: *Builder,
        imported_definition: *const definition.Plan,
    ) !*Plan {
        const imported_plan = try self.allocator.create(Plan);
        var imported_plan_initialized = false;
        errdefer {
            if (imported_plan_initialized) {
                imported_plan.deinit(self.allocator);
            }
            self.allocator.destroy(imported_plan);
        }
        imported_plan.* = try compile(
            self.allocator,
            imported_definition,
        );
        imported_plan_initialized = true;
        for (imported_plan.rules) |imported_rule| {
            if (!isValidationOperator(imported_rule.operator)) {
                return error.UnsupportedImportedDefinitionRule;
            }
        }
        return imported_plan;
    }

    fn compileSha256Rule(
        self: *Builder,
        object: std.json.ObjectMap,
        allow_input: bool,
        rule: *CompiledRule,
    ) anyerror!void {
        try requireSha256Keys(object, allow_input);
        try definition_core.json.requireFields(
            object,
            &.{ "op", "mode", "field", "max_bytes" },
        );
        try self.compileSha256Header(object, rule);
        switch (rule.sha256_mode.?) {
            .canonical_json => try self.compileSha256Canonical(
                object,
                rule,
                false,
            ),
            .canonical_json_null => try self.compileSha256Canonical(
                object,
                rule,
                true,
            ),
            .framed_items => try self.compileSha256Items(object, rule),
            .framed_fields => try self.compileSha256Fields(object, rule),
        }
    }

    fn requireSha256Keys(
        object: std.json.ObjectMap,
        allow_input: bool,
    ) !void {
        if (allow_input) {
            try definition_core.json.requireExactKeys(
                object,
                &.{
                    "op",
                    "input",
                    "path",
                    "mode",
                    "field",
                    "field_input",
                    "allow_bare",
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
                    "field_input",
                    "allow_bare",
                    "null",
                    "items",
                    "prefix",
                    "fragments",
                    "max_bytes",
                },
            );
        }
    }

    fn compileSha256Header(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) !void {
        const mode = try definition_core.json.requiredString(object, "mode");
        rule.sha256_mode = if (std.mem.eql(
            u8,
            mode,
            "canonical-json",
        ))
            .canonical_json
        else if (std.mem.eql(
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
        rule.other_input_index = if (object.get("field_input")) |raw|
            try self.inputIndex(try definition_core.json.string(raw))
        else
            null;
        rule.allow_bare_digest =
            try optionalBoolean(object, "allow_bare") orelse false;
        rule.max_count = try optionalUnsigned(object, "max_bytes") orelse
            return error.MissingSha256Bound;
        if (rule.max_count.? == 0 or
            rule.max_count.? > max_sha256_subject_bytes)
        {
            return error.InvalidSha256Bound;
        }
    }

    fn compileSha256Canonical(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
        null_field_required: bool,
    ) !void {
        if (null_field_required) {
            try definition_core.json.requireFields(object, &.{"null"});
        }
        if (object.get("items") != null or
            object.get("prefix") != null or
            object.get("fragments") != null)
        {
            return error.ConflictingSha256ModeFields;
        }
        if (null_field_required) {
            const null_pointer = try self.internPointer(
                try definition_core.json.requiredString(object, "null"),
            );
            if (self.pointers.items[null_pointer].raw.len == 0) {
                return error.Sha256NullPointerEmpty;
            }
            const path_ids = try self.allocator.alloc(u16, 1);
            path_ids[0] = null_pointer;
            self.allocator.free(rule.path_ids);
            rule.path_ids = path_ids;
        } else if (object.get("null") != null) {
            return error.ConflictingSha256ModeFields;
        }
    }

    fn compileSha256Items(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) !void {
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
        try self.compileSha256Framing(object, rule);
    }

    fn compileSha256Fields(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) !void {
        try definition_core.json.requireFields(
            object,
            &.{ "prefix", "fragments" },
        );
        if (object.get("null") != null or object.get("items") != null) {
            return error.ConflictingSha256ModeFields;
        }
        try self.compileSha256Framing(object, rule);
        for (rule.format_parts) |part| switch (part) {
            .literal, .parent => {},
            .item, .value => return error.InvalidSha256FieldFragment,
        };
    }

    fn compileSha256Framing(
        self: *Builder,
        object: std.json.ObjectMap,
        rule: *CompiledRule,
    ) !void {
        const prefix = (try definition_core.json.optionalString(
            object,
            "prefix",
        )) orelse return error.MissingField;
        if (prefix.len > 4096) {
            return error.Sha256PrefixBytesExceeded;
        }
        rule.sha256_prefix = try self.allocator.dupe(u8, prefix);
        rule.format_parts = try self.compileFormatParts(
            try definition_core.json.field(object, "fragments"),
            false,
        );
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
            var variant = try self.compileVariant(
                raw_variant,
                input_index,
                depth,
                rule.other_pointer_id != null,
            );
            errdefer variant.deinit(self.allocator);
            if (variantDuplicates(variant, variants[0..initialized])) {
                return error.DuplicateTaggedUnionVariant;
            }
            variants[index] = variant;
            initialized += 1;
        }
        rule.variants = variants;
    }

    fn compileVariant(
        self: *Builder,
        raw: std.json.Value,
        input_index: u8,
        depth: usize,
        tagged: bool,
    ) anyerror!CompiledVariant {
        const object = try definition_core.json.object(raw);
        if (tagged) {
            try definition_core.json.requireExactKeys(
                object,
                &.{ "value", "rules" },
            );
            try definition_core.json.requireFields(
                object,
                &.{ "value", "rules" },
            );
        } else {
            try definition_core.json.requireExactKeys(
                object,
                &.{ "kind", "rules" },
            );
            try definition_core.json.requireFields(
                object,
                &.{ "kind", "rules" },
            );
        }
        return .{
            .kind = if (!tagged)
                try JsonKind.parse(
                    try definition_core.json.requiredString(object, "kind"),
                )
            else
                null,
            .tag_value = if (tagged)
                try parseEnumScalar(
                    self.allocator,
                    try definition_core.json.field(object, "value"),
                )
            else
                null,
            .rules = try self.compileVariantRules(
                try definition_core.json.field(object, "rules"),
                input_index,
                depth + 1,
            ),
        };
    }

    fn variantDuplicates(
        variant: CompiledVariant,
        prior_variants: []const CompiledVariant,
    ) bool {
        for (prior_variants) |prior| {
            if (variant.kind != null and prior.kind == variant.kind) return true;
            if (variant.tag_value != null and prior.tag_value != null and
                enumScalarsEqual(variant.tag_value.?, prior.tag_value.?))
            {
                return true;
            }
        }
        return false;
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
    errdefer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    const root_traversal = try compileRootTraversal(
        allocator,
        pointers,
        rules,
    );
    errdefer root_traversal.deinit(allocator);
    return .{
        .inputs = inputs,
        .pointers = pointers,
        .rules = rules,
        .root_shared_prefixes = root_traversal.shared_prefixes,
        .max_root_pointer_depth = root_traversal.max_depth,
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
    errdefer {
        for (compiled_rules) |*rule| rule.deinit(allocator);
        allocator.free(compiled_rules);
    }
    const root_traversal = try compileRootTraversal(
        allocator,
        pointers,
        compiled_rules,
    );
    errdefer root_traversal.deinit(allocator);
    return .{
        .inputs = owned_inputs,
        .pointers = pointers,
        .rules = compiled_rules,
        .root_shared_prefixes = root_traversal.shared_prefixes,
        .max_root_pointer_depth = root_traversal.max_depth,
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
    try encoder.writeU16(33);
    try encodeCachePlan(plan, encoder, 0);
}

fn encodeCachePlan(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
    depth: usize,
) anyerror!void {
    const allocator = std.heap.page_allocator;
    var tasks: std.ArrayList(CacheEncodeTask) = .empty;
    defer tasks.deinit(allocator);
    try pushCacheEncodeTask(
        &tasks,
        allocator,
        .{ .plan = .{ .plan = plan, .depth = depth } },
    );
    while (tasks.pop()) |task| {
        try encodeCacheTask(&tasks, allocator, encoder, task);
    }
}

const CacheEncodePlan = struct {
    plan: *const Plan,
    depth: usize,
};

const CacheEncodeRule = struct {
    rule: *const CompiledRule,
    depth: usize,
};

const CacheEncodeRuleGroup = struct {
    rules: []const CompiledRule,
    depth: usize,
};

const CacheEncodeTask = union(enum) {
    plan: CacheEncodePlan,
    plan_finish: *const Plan,
    rule: CacheEncodeRule,
    rule_group: CacheEncodeRuleGroup,
    variants: CacheEncodeRule,
    variant: struct {
        variant: *const CompiledVariant,
        depth: usize,
    },
    suffix: *const CompiledRule,
    sources: CacheEncodeRule,
    source: struct {
        source: *const CompiledReferenceSource,
        depth: usize,
    },
    targets: CacheEncodeRule,
    target: struct {
        target: *const CompiledReferenceTarget,
        depth: usize,
    },
    imported: CacheEncodeRule,
    format_parts: []const CompiledFormatPart,
};

fn pushCacheEncodeTask(
    tasks: *std.ArrayList(CacheEncodeTask),
    allocator: std.mem.Allocator,
    task: CacheEncodeTask,
) !void {
    if (tasks.items.len == max_cache_rule_tasks) {
        return error.CacheRuleCountExceeded;
    }
    try tasks.append(allocator, task);
}

fn encodeCacheTask(
    tasks: *std.ArrayList(CacheEncodeTask),
    allocator: std.mem.Allocator,
    encoder: *definition_core.cache.Encoder,
    task: CacheEncodeTask,
) anyerror!void {
    switch (task) {
        .plan => |value| try encodeCachePlanTask(tasks, allocator, encoder, value),
        .plan_finish => |plan| try encodeCachePlanFinish(encoder, plan),
        .rule => |value| try encodeCacheRuleTask(tasks, allocator, encoder, value),
        .rule_group => |value| try encodeCacheRuleGroupTask(
            tasks,
            allocator,
            encoder,
            value,
        ),
        .variants => |value| try encodeCacheVariantsTask(
            tasks,
            allocator,
            encoder,
            value,
        ),
        .variant => |value| try encodeCacheVariantTask(
            tasks,
            allocator,
            encoder,
            value.variant,
            value.depth,
        ),
        .suffix => |rule| try encodeCacheRuleSuffix(encoder, rule),
        .sources => |value| try encodeCacheSourcesTask(tasks, allocator, encoder, value),
        .source => |value| try encodeCacheSourceTask(
            tasks,
            allocator,
            encoder,
            value.source,
            value.depth,
        ),
        .targets => |value| try encodeCacheTargetsTask(tasks, allocator, encoder, value),
        .target => |value| try encodeCacheTargetTask(
            tasks,
            allocator,
            encoder,
            value.target,
            value.depth,
        ),
        .imported => |value| try encodeCacheImportedTask(
            tasks,
            allocator,
            encoder,
            value,
        ),
        .format_parts => |parts| try encodeCompiledFormatParts(encoder, parts),
    }
}

fn encodeCachePlanTask(
    tasks: *std.ArrayList(CacheEncodeTask),
    allocator: std.mem.Allocator,
    encoder: *definition_core.cache.Encoder,
    value: CacheEncodePlan,
) !void {
    if (value.depth > 32) return error.ImportDepthExceeded;
    try encoder.writeCount(value.plan.inputs.len);
    for (value.plan.inputs) |input| {
        try encoder.writeBytes(input.name);
        try encoder.writeEnum(input.codec);
        try encoder.writeBool(input.required);
        try encoder.writeUsize(input.max_bytes);
    }
    try encoder.writeCount(value.plan.pointers.len);
    for (value.plan.pointers) |pointer| {
        try encoder.writeBytes(pointer.raw);
    }
    try pushCacheEncodeTask(
        tasks,
        allocator,
        .{ .plan_finish = value.plan },
    );
    try pushCacheEncodeTask(
        tasks,
        allocator,
        .{ .rule_group = .{
            .rules = value.plan.rules,
            .depth = value.depth,
        } },
    );
}

fn encodeCachePlanFinish(
    encoder: *definition_core.cache.Encoder,
    plan: *const Plan,
) !void {
    try encoder.writeUsize(plan.max_input_bytes);
    try encoder.writeUsize(plan.max_records);
    try encoder.writeUsize(plan.max_diagnostics);
}

fn encodeCacheRuleGroupTask(
    tasks: *std.ArrayList(CacheEncodeTask),
    allocator: std.mem.Allocator,
    encoder: *definition_core.cache.Encoder,
    value: CacheEncodeRuleGroup,
) !void {
    try encoder.writeCount(value.rules.len);
    var index = value.rules.len;
    while (index > 0) {
        index -= 1;
        try pushCacheEncodeTask(
            tasks,
            allocator,
            .{ .rule = .{
                .rule = &value.rules[index],
                .depth = value.depth,
            } },
        );
    }
}

fn encodeCacheRuleTask(
    tasks: *std.ArrayList(CacheEncodeTask),
    allocator: std.mem.Allocator,
    encoder: *definition_core.cache.Encoder,
    value: CacheEncodeRule,
) !void {
    try encodeCacheRuleHeader(encoder, value.rule);
    const followups = [_]CacheEncodeTask{
        .{ .imported = value },
        .{ .targets = value },
        .{ .sources = value },
        .{ .suffix = value.rule },
        .{ .variants = value },
        .{ .rule_group = .{
            .rules = value.rule.coverage_children,
            .depth = value.depth,
        } },
        .{ .rule_group = .{
            .rules = value.rule.children,
            .depth = value.depth,
        } },
    };
    for (followups) |task| {
        try pushCacheEncodeTask(tasks, allocator, task);
    }
}

fn encodeCacheRuleHeader(
    encoder: *definition_core.cache.Encoder,
    rule: *const CompiledRule,
) !void {
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
    try writeOptionalEnumScalar(encoder, rule.min_number);
    try writeOptionalEnumScalar(encoder, rule.max_number);
    try encoder.writeEnum(rule.identifier_style);
    try encoder.writeBool(rule.allow_root);
    try encoder.writeBool(rule.case_insensitive);
    try encoder.writeBool(rule.allow_additional);
    try encoder.writeBool(rule.allow_null);
    try encoder.writeBool(rule.allow_bare_digest);
    try encoder.writeBool(rule.total_coverage);
    try encoder.writeBool(rule.reject_self_reference);
    try encoder.writeBool(rule.ignore_null_references);
    try encoder.writeBool(rule.then_nonempty);
}

fn encodeCacheVariantsTask(
    tasks: *std.ArrayList(CacheEncodeTask),
    allocator: std.mem.Allocator,
    encoder: *definition_core.cache.Encoder,
    value: CacheEncodeRule,
) !void {
    try encoder.writeCount(value.rule.variants.len);
    var index = value.rule.variants.len;
    while (index > 0) {
        index -= 1;
        try pushCacheEncodeTask(
            tasks,
            allocator,
            .{ .variant = .{
                .variant = &value.rule.variants[index],
                .depth = value.depth,
            } },
        );
    }
}

fn encodeCacheVariantTask(
    tasks: *std.ArrayList(CacheEncodeTask),
    allocator: std.mem.Allocator,
    encoder: *definition_core.cache.Encoder,
    variant: *const CompiledVariant,
    depth: usize,
) !void {
    if (variant.kind) |kind| {
        try encoder.writeByte(0);
        try encoder.writeEnum(kind);
    } else if (variant.tag_value) |tag_value| {
        try encoder.writeByte(1);
        try encodeEnumScalar(encoder, tag_value);
    } else {
        return error.TaggedUnionVariantInvalid;
    }
    try pushCacheEncodeTask(
        tasks,
        allocator,
        .{ .rule_group = .{ .rules = variant.rules, .depth = depth } },
    );
}

fn encodeCacheRuleSuffix(
    encoder: *definition_core.cache.Encoder,
    rule: *const CompiledRule,
) !void {
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
}

fn encodeCacheSourcesTask(
    tasks: *std.ArrayList(CacheEncodeTask),
    allocator: std.mem.Allocator,
    encoder: *definition_core.cache.Encoder,
    value: CacheEncodeRule,
) !void {
    try encoder.writeCount(value.rule.reference_sources.len);
    var index = value.rule.reference_sources.len;
    while (index > 0) {
        index -= 1;
        try pushCacheEncodeTask(
            tasks,
            allocator,
            .{ .source = .{
                .source = &value.rule.reference_sources[index],
                .depth = value.depth,
            } },
        );
    }
}

fn encodeCacheSourceTask(
    tasks: *std.ArrayList(CacheEncodeTask),
    allocator: std.mem.Allocator,
    encoder: *definition_core.cache.Encoder,
    source: *const CompiledReferenceSource,
    depth: usize,
) !void {
    try encoder.writeU16(source.pointer_id);
    try writeOptionalU16(encoder, source.items_pointer_id);
    try encoder.writeU16(source.reference_pointer_id);
    try encoder.writeBool(source.optional);
    try encoder.writeBool(source.singleton);
    try pushCacheEncodeTask(
        tasks,
        allocator,
        .{ .format_parts = source.format_parts },
    );
    try pushCacheEncodeTask(
        tasks,
        allocator,
        .{ .rule_group = .{ .rules = source.rules, .depth = depth } },
    );
}

fn encodeCacheTargetsTask(
    tasks: *std.ArrayList(CacheEncodeTask),
    allocator: std.mem.Allocator,
    encoder: *definition_core.cache.Encoder,
    value: CacheEncodeRule,
) !void {
    try encoder.writeCount(value.rule.reference_targets.len);
    var index = value.rule.reference_targets.len;
    while (index > 0) {
        index -= 1;
        try pushCacheEncodeTask(
            tasks,
            allocator,
            .{ .target = .{
                .target = &value.rule.reference_targets[index],
                .depth = value.depth,
            } },
        );
    }
}

fn encodeCacheTargetTask(
    tasks: *std.ArrayList(CacheEncodeTask),
    allocator: std.mem.Allocator,
    encoder: *definition_core.cache.Encoder,
    target: *const CompiledReferenceTarget,
    depth: usize,
) !void {
    try encoder.writeU16(target.pointer_id);
    try encoder.writeBool(target.optional);
    try writeOptionalU16(encoder, target.items_pointer_id);
    try writeOptionalU16(encoder, target.key_pointer_id);
    try writeOptionalU16(encoder, target.coverage_key_pointer_id);
    const followups = [_]CacheEncodeTask{
        .{ .format_parts = target.format_parts },
        .{ .rule_group = .{ .rules = target.coverage_rules, .depth = depth } },
        .{ .rule_group = .{ .rules = target.match_rules, .depth = depth } },
        .{ .rule_group = .{ .rules = target.rules, .depth = depth } },
    };
    for (followups) |task| {
        try pushCacheEncodeTask(tasks, allocator, task);
    }
}

fn encodeCacheImportedTask(
    tasks: *std.ArrayList(CacheEncodeTask),
    allocator: std.mem.Allocator,
    encoder: *definition_core.cache.Encoder,
    value: CacheEncodeRule,
) !void {
    try encoder.writeBool(value.rule.imported_plan != null);
    if (value.rule.imported_plan) |imported_plan| {
        try pushCacheEncodeTask(
            tasks,
            allocator,
            .{ .plan = .{
                .plan = imported_plan,
                .depth = value.depth + 1,
            } },
        );
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 33) {
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
    const root_traversal = try compileRootTraversal(
        allocator,
        pointers,
        rules,
    );
    errdefer root_traversal.deinit(allocator);
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
        .root_shared_prefixes = root_traversal.shared_prefixes,
        .max_root_pointer_depth = root_traversal.max_depth,
        .max_input_bytes = max_input_bytes,
        .max_records = max_records,
        .max_diagnostics = max_diagnostics,
    };
}

pub fn validateCachePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
) anyerror!void {
    try validateCachePlanHeader(plan, definition_plan);
    try validateRuleGraph(plan.rules, definition_plan);
}

fn validateCachePlanHeader(
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
    try validateRuleGraph(plan.rules, definition_plan);
}

const CacheRuleTask = struct {
    rule: *const CompiledRule,
    definition_plan: *const definition.Plan,
};

fn validateRuleGraph(
    root_rules: []const CompiledRule,
    definition_plan: *const definition.Plan,
) !void {
    const allocator = std.heap.page_allocator;
    var tasks: std.ArrayList(CacheRuleTask) = .empty;
    defer tasks.deinit(allocator);
    try appendCacheRuleTasks(&tasks, allocator, root_rules, definition_plan);
    while (tasks.pop()) |task| {
        try validateCacheRuleTask(&tasks, allocator, task);
    }
}

fn appendCacheRuleTasks(
    tasks: *std.ArrayList(CacheRuleTask),
    allocator: std.mem.Allocator,
    rules: []const CompiledRule,
    definition_plan: *const definition.Plan,
) !void {
    if (rules.len > max_cache_rule_tasks - tasks.items.len) {
        return error.CacheRuleCountExceeded;
    }
    for (rules) |*rule| {
        try tasks.append(allocator, .{
            .rule = rule,
            .definition_plan = definition_plan,
        });
    }
}

fn validateCacheRuleTask(
    tasks: *std.ArrayList(CacheRuleTask),
    allocator: std.mem.Allocator,
    task: CacheRuleTask,
) !void {
    const rule = task.rule;
    const definition_plan = task.definition_plan;
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
        const imported_definition = &definition_plan.imports[import_index];
        try validateCachePlanHeader(rule.imported_plan.?, imported_definition);
        try appendCacheRuleTasks(
            tasks,
            allocator,
            rule.imported_plan.?.rules,
            imported_definition,
        );
    } else if (rule.import_index != null or rule.imported_plan != null) {
        return error.CacheValidationPlanMismatch;
    }
    try appendNestedCacheRules(tasks, allocator, rule, definition_plan);
    try appendReferenceCacheRules(tasks, allocator, rule, definition_plan);
}

fn appendNestedCacheRules(
    tasks: *std.ArrayList(CacheRuleTask),
    allocator: std.mem.Allocator,
    rule: *const CompiledRule,
    definition_plan: *const definition.Plan,
) !void {
    for (rule.children) |*child| {
        if (rule.operator == .implies) {
            if (!isValidationOperator(child.operator)) {
                return error.CacheValidationPlanMismatch;
            }
        } else if (child.input_index != rule.input_index or
            !isItemOperator(child.operator))
        {
            return error.CacheValidationPlanMismatch;
        }
    }
    try appendCacheRuleTasks(
        tasks,
        allocator,
        rule.children,
        definition_plan,
    );
    for (rule.coverage_children) |*child| {
        if (child.input_index != rule.other_input_index.? or
            !isItemOperator(child.operator))
        {
            return error.CacheValidationPlanMismatch;
        }
    }
    try appendCacheRuleTasks(
        tasks,
        allocator,
        rule.coverage_children,
        definition_plan,
    );
}

fn appendReferenceCacheRules(
    tasks: *std.ArrayList(CacheRuleTask),
    allocator: std.mem.Allocator,
    rule: *const CompiledRule,
    definition_plan: *const definition.Plan,
) !void {
    for (rule.reference_targets) |target| {
        try appendTargetCacheRules(
            tasks,
            allocator,
            rule,
            target,
            definition_plan,
        );
    }
    for (rule.reference_sources) |source| {
        for (source.rules) |source_rule| {
            if (source_rule.input_index != rule.input_index or
                !isItemOperator(source_rule.operator))
            {
                return error.CacheValidationPlanMismatch;
            }
        }
        try appendCacheRuleTasks(
            tasks,
            allocator,
            source.rules,
            definition_plan,
        );
    }
    for (rule.variants) |variant| {
        for (variant.rules) |variant_rule| {
            if (variant_rule.input_index != rule.input_index or
                !isItemOperator(variant_rule.operator))
            {
                return error.CacheValidationPlanMismatch;
            }
        }
        try appendCacheRuleTasks(
            tasks,
            allocator,
            variant.rules,
            definition_plan,
        );
    }
}

fn appendTargetCacheRules(
    tasks: *std.ArrayList(CacheRuleTask),
    allocator: std.mem.Allocator,
    parent: *const CompiledRule,
    target: CompiledReferenceTarget,
    definition_plan: *const definition.Plan,
) !void {
    const groups = [_][]const CompiledRule{
        target.rules,
        target.match_rules,
        target.coverage_rules,
    };
    for (groups) |rules| {
        for (rules) |target_rule| {
            if (target_rule.input_index != parent.other_input_index.? or
                !isItemOperator(target_rule.operator))
            {
                return error.CacheValidationPlanMismatch;
            }
        }
        try appendCacheRuleTasks(tasks, allocator, rules, definition_plan);
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

const CacheRuleDecodeContext = struct {
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    input_count: usize,
    pointer_count: usize,
    depth: usize,
    total_rule_count: *usize,
    plan_depth: usize,
    imported_plan_count: *usize,

    fn decodeRules(self: CacheRuleDecodeContext) anyerror![]CompiledRule {
        return decodeCacheRules(
            self.allocator,
            self.decoder,
            self.input_count,
            self.pointer_count,
            self.depth + 1,
            self.total_rule_count,
            self.plan_depth,
            self.imported_plan_count,
        );
    }
};

const DecodedCacheRuleHeader = struct {
    operator: definition.Operator,
    input_index: u8,
    pointer_id: ?u16,
    import_index: ?u16,
    other_input_index: ?u8,
    other_pointer_id: ?u16,
    path_ids: []u16,
    keys: [][]u8,
    optional_keys: [][]u8,
    values: []EnumScalar,
    scalar_kind: ?JsonKind,
    min_count: ?usize,
    max_count: ?usize,
    trimmed_min_count: ?usize,
    min_number: ?EnumScalar,
    max_number: ?EnumScalar,
    identifier_style: IdentifierStyle,
    allow_root: bool,
    case_insensitive: bool,
    allow_additional: bool,
    allow_null: bool,
    allow_bare_digest: bool,
    total_coverage: bool,
    reject_self_reference: bool,
    ignore_null_references: bool,
    then_nonempty: bool,

    fn deinit(
        self: *DecodedCacheRuleHeader,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.path_ids);
        deinitKeySlices(allocator, self.keys);
        deinitKeySlices(allocator, self.optional_keys);
        for (self.values) |*value| value.deinit(allocator);
        allocator.free(self.values);
        if (self.min_number) |*value| value.deinit(allocator);
        if (self.max_number) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

const DecodedCacheRuleNested = struct {
    children: []CompiledRule,
    coverage_children: []CompiledRule,
    variants: []CompiledVariant,

    fn deinit(
        self: *DecodedCacheRuleNested,
        allocator: std.mem.Allocator,
    ) void {
        deinitRuleSlice(allocator, self.children);
        deinitRuleSlice(allocator, self.coverage_children);
        for (self.variants) |*variant| variant.deinit(allocator);
        allocator.free(self.variants);
        self.* = undefined;
    }
};

const DecodedCacheRuleTail = struct {
    format_parts: []CompiledFormatPart,
    regex_patterns: []CompiledRegexPattern,
    sha256_mode: ?Sha256Mode,
    sha256_prefix: ?[]u8,
    reference_sources: []CompiledReferenceSource,
    reference_targets: []CompiledReferenceTarget,
    imported_plan: ?*Plan,

    fn deinit(
        self: *DecodedCacheRuleTail,
        allocator: std.mem.Allocator,
    ) void {
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
    const context: CacheRuleDecodeContext = .{
        .allocator = allocator,
        .decoder = decoder,
        .input_count = input_count,
        .pointer_count = pointer_count,
        .depth = depth,
        .total_rule_count = total_rule_count,
        .plan_depth = plan_depth,
        .imported_plan_count = imported_plan_count,
    };
    var header = try decodeCacheRuleHeader(context);
    errdefer header.deinit(allocator);
    var nested = try decodeCacheRuleNested(context);
    errdefer nested.deinit(allocator);
    var tail = try decodeCacheRuleTail(context);
    errdefer tail.deinit(allocator);
    const rule: CompiledRule = .{
        .operator = header.operator,
        .input_index = header.input_index,
        .pointer_id = header.pointer_id,
        .import_index = header.import_index,
        .imported_plan = tail.imported_plan,
        .other_input_index = header.other_input_index,
        .other_pointer_id = header.other_pointer_id,
        .path_ids = header.path_ids,
        .keys = header.keys,
        .optional_keys = header.optional_keys,
        .values = header.values,
        .scalar_kind = header.scalar_kind,
        .min_count = header.min_count,
        .max_count = header.max_count,
        .trimmed_min_count = header.trimmed_min_count,
        .min_number = header.min_number,
        .max_number = header.max_number,
        .identifier_style = header.identifier_style,
        .allow_root = header.allow_root,
        .case_insensitive = header.case_insensitive,
        .allow_additional = header.allow_additional,
        .allow_null = header.allow_null,
        .allow_bare_digest = header.allow_bare_digest,
        .total_coverage = header.total_coverage,
        .reject_self_reference = header.reject_self_reference,
        .ignore_null_references = header.ignore_null_references,
        .then_nonempty = header.then_nonempty,
        .children = nested.children,
        .coverage_children = nested.coverage_children,
        .variants = nested.variants,
        .format_parts = tail.format_parts,
        .regex_patterns = tail.regex_patterns,
        .sha256_mode = tail.sha256_mode,
        .sha256_prefix = tail.sha256_prefix,
        .reference_sources = tail.reference_sources,
        .reference_targets = tail.reference_targets,
    };
    try validateCachedRule(rule, input_count, pointer_count);
    return rule;
}

fn decodeCacheRuleHeader(
    context: CacheRuleDecodeContext,
) !DecodedCacheRuleHeader {
    const operator = try context.decoder.readEnum(definition.Operator);
    const input_index = try context.decoder.readByte();
    const pointer_id = try readOptionalU16(context.decoder);
    const import_index = try readOptionalU16(context.decoder);
    const other_input_index = try readOptionalByte(context.decoder);
    const other_pointer_id = try readOptionalU16(context.decoder);
    const path_ids = try decodePathIds(context.allocator, context.decoder);
    errdefer context.allocator.free(path_ids);
    const keys = try decodeKeys(context.allocator, context.decoder);
    errdefer deinitKeySlices(context.allocator, keys);
    const optional_keys = try decodeKeys(context.allocator, context.decoder);
    errdefer deinitKeySlices(context.allocator, optional_keys);
    const values = try decodeEnumScalars(context.allocator, context.decoder);
    errdefer {
        for (values) |*value| value.deinit(context.allocator);
        context.allocator.free(values);
    }
    const scalar_kind = if (try context.decoder.readBool())
        try context.decoder.readEnum(JsonKind)
    else
        null;
    const min_count = try readOptionalUsize(context.decoder);
    const max_count = try readOptionalUsize(context.decoder);
    const trimmed_min_count = try readOptionalUsize(context.decoder);
    var min_number = try readOptionalEnumScalar(
        context.allocator,
        context.decoder,
    );
    errdefer if (min_number) |*value| value.deinit(context.allocator);
    var max_number = try readOptionalEnumScalar(
        context.allocator,
        context.decoder,
    );
    errdefer if (max_number) |*value| value.deinit(context.allocator);
    return .{
        .operator = operator,
        .input_index = input_index,
        .pointer_id = pointer_id,
        .import_index = import_index,
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
        .identifier_style = try context.decoder.readEnum(IdentifierStyle),
        .allow_root = try context.decoder.readBool(),
        .case_insensitive = try context.decoder.readBool(),
        .allow_additional = try context.decoder.readBool(),
        .allow_null = try context.decoder.readBool(),
        .allow_bare_digest = try context.decoder.readBool(),
        .total_coverage = try context.decoder.readBool(),
        .reject_self_reference = try context.decoder.readBool(),
        .ignore_null_references = try context.decoder.readBool(),
        .then_nonempty = try context.decoder.readBool(),
    };
}

fn decodeCacheRuleNested(
    context: CacheRuleDecodeContext,
) anyerror!DecodedCacheRuleNested {
    const children = try context.decodeRules();
    errdefer deinitRuleSlice(context.allocator, children);
    const coverage_children = try context.decodeRules();
    errdefer deinitRuleSlice(context.allocator, coverage_children);
    const variants = try decodeCacheVariants(context);
    errdefer {
        for (variants) |*variant| variant.deinit(context.allocator);
        context.allocator.free(variants);
    }
    return .{
        .children = children,
        .coverage_children = coverage_children,
        .variants = variants,
    };
}

fn decodeCacheVariants(
    context: CacheRuleDecodeContext,
) anyerror![]CompiledVariant {
    const count = try context.decoder.readCount(64);
    const variants = try context.allocator.alloc(CompiledVariant, count);
    var initialized: usize = 0;
    errdefer {
        for (variants[0..initialized]) |*variant| {
            variant.deinit(context.allocator);
        }
        context.allocator.free(variants);
    }
    for (variants) |*variant| {
        variant.* = try decodeCacheVariant(context);
        initialized += 1;
    }
    return variants;
}

fn decodeCacheVariant(
    context: CacheRuleDecodeContext,
) anyerror!CompiledVariant {
    var tag_value: ?EnumScalar = null;
    errdefer if (tag_value) |*value| value.deinit(context.allocator);
    const kind: ?JsonKind = switch (try context.decoder.readByte()) {
        0 => try context.decoder.readEnum(JsonKind),
        1 => tag: {
            tag_value = try decodeEnumScalar(
                context.allocator,
                context.decoder,
            );
            break :tag null;
        },
        else => return error.CacheTaggedUnionVariantInvalid,
    };
    return .{
        .kind = kind,
        .tag_value = tag_value,
        .rules = try context.decodeRules(),
    };
}

fn decodeCacheRuleTail(
    context: CacheRuleDecodeContext,
) anyerror!DecodedCacheRuleTail {
    const format_parts = try decodeCompiledFormatParts(
        context.allocator,
        context.decoder,
    );
    errdefer deinitFormatParts(context.allocator, format_parts);
    const regex_patterns = try decodeCompiledRegexPatterns(
        context.allocator,
        context.decoder,
    );
    errdefer deinitRegexPatterns(context.allocator, regex_patterns);
    const sha256_mode = if (try context.decoder.readBool())
        try context.decoder.readEnum(Sha256Mode)
    else
        null;
    const sha256_prefix = try context.decoder.readOptionalBytesAlloc(
        context.allocator,
        4096,
    );
    errdefer if (sha256_prefix) |prefix| context.allocator.free(prefix);
    const reference_sources = try decodeCacheReferenceSources(context);
    errdefer deinitReferenceSources(context.allocator, reference_sources);
    const reference_targets = try decodeCacheReferenceTargets(context);
    errdefer deinitReferenceTargets(context.allocator, reference_targets);
    const imported_plan = try decodeCacheImportedPlan(context);
    errdefer if (imported_plan) |plan| {
        plan.deinit(context.allocator);
        context.allocator.destroy(plan);
    };
    return .{
        .format_parts = format_parts,
        .regex_patterns = regex_patterns,
        .sha256_mode = sha256_mode,
        .sha256_prefix = sha256_prefix,
        .reference_sources = reference_sources,
        .reference_targets = reference_targets,
        .imported_plan = imported_plan,
    };
}

fn decodeCacheReferenceSources(
    context: CacheRuleDecodeContext,
) anyerror![]CompiledReferenceSource {
    const count = try context.decoder.readCount(64);
    const sources = try context.allocator.alloc(CompiledReferenceSource, count);
    var initialized: usize = 0;
    errdefer {
        for (sources[0..initialized]) |*source| {
            source.deinit(context.allocator);
        }
        context.allocator.free(sources);
    }
    for (sources) |*source| {
        source.* = try decodeCacheReferenceSource(context);
        initialized += 1;
    }
    return sources;
}

fn decodeCacheReferenceSource(
    context: CacheRuleDecodeContext,
) anyerror!CompiledReferenceSource {
    const pointer_id = try context.decoder.readU16();
    const items_pointer_id = try readOptionalU16(context.decoder);
    const reference_pointer_id = try context.decoder.readU16();
    const optional = try context.decoder.readBool();
    const singleton = try context.decoder.readBool();
    const rules = try context.decodeRules();
    errdefer deinitRuleSlice(context.allocator, rules);
    return .{
        .pointer_id = pointer_id,
        .items_pointer_id = items_pointer_id,
        .reference_pointer_id = reference_pointer_id,
        .optional = optional,
        .singleton = singleton,
        .rules = rules,
        .format_parts = try decodeCompiledFormatParts(
            context.allocator,
            context.decoder,
        ),
    };
}

fn decodeCacheReferenceTargets(
    context: CacheRuleDecodeContext,
) anyerror![]CompiledReferenceTarget {
    const count = try context.decoder.readCount(64);
    const targets = try context.allocator.alloc(CompiledReferenceTarget, count);
    var initialized: usize = 0;
    errdefer {
        for (targets[0..initialized]) |*target| {
            target.deinit(context.allocator);
        }
        context.allocator.free(targets);
    }
    for (targets) |*target| {
        target.* = try decodeCacheReferenceTarget(context);
        initialized += 1;
    }
    return targets;
}

fn decodeCacheReferenceTarget(
    context: CacheRuleDecodeContext,
) anyerror!CompiledReferenceTarget {
    const pointer_id = try context.decoder.readU16();
    const optional = try context.decoder.readBool();
    const items_pointer_id = try readOptionalU16(context.decoder);
    const key_pointer_id = try readOptionalU16(context.decoder);
    const coverage_key_pointer_id = try readOptionalU16(context.decoder);
    const rules = try context.decodeRules();
    errdefer deinitRuleSlice(context.allocator, rules);
    const match_rules = try context.decodeRules();
    errdefer deinitRuleSlice(context.allocator, match_rules);
    const coverage_rules = try context.decodeRules();
    errdefer deinitRuleSlice(context.allocator, coverage_rules);
    const format_parts = try decodeCompiledFormatParts(
        context.allocator,
        context.decoder,
    );
    errdefer deinitFormatParts(context.allocator, format_parts);
    return .{
        .pointer_id = pointer_id,
        .optional = optional,
        .items_pointer_id = items_pointer_id,
        .key_pointer_id = key_pointer_id,
        .coverage_key_pointer_id = coverage_key_pointer_id,
        .rules = rules,
        .match_rules = match_rules,
        .coverage_rules = coverage_rules,
        .format_parts = format_parts,
    };
}

fn decodeCacheImportedPlan(
    context: CacheRuleDecodeContext,
) anyerror!?*Plan {
    if (!try context.decoder.readBool()) return null;
    const plan = try context.allocator.create(Plan);
    errdefer context.allocator.destroy(plan);
    plan.* = try decodeCachePlan(
        context.allocator,
        context.decoder,
        context.plan_depth + 1,
        context.imported_plan_count,
    );
    return plan;
}

fn deinitKeySlices(
    allocator: std.mem.Allocator,
    keys: [][]u8,
) void {
    for (keys) |key| allocator.free(key);
    allocator.free(keys);
}

fn deinitRuleSlice(
    allocator: std.mem.Allocator,
    rules: []CompiledRule,
) void {
    for (rules) |*rule| rule.deinit(allocator);
    allocator.free(rules);
}

fn deinitFormatParts(
    allocator: std.mem.Allocator,
    parts: []CompiledFormatPart,
) void {
    for (parts) |*part| part.deinit(allocator);
    allocator.free(parts);
}

fn deinitRegexPatterns(
    allocator: std.mem.Allocator,
    patterns: []CompiledRegexPattern,
) void {
    for (patterns) |*pattern| pattern.deinit(allocator);
    allocator.free(patterns);
}

fn deinitReferenceSources(
    allocator: std.mem.Allocator,
    sources: []CompiledReferenceSource,
) void {
    for (sources) |*source| source.deinit(allocator);
    allocator.free(sources);
}

fn deinitReferenceTargets(
    allocator: std.mem.Allocator,
    targets: []CompiledReferenceTarget,
) void {
    for (targets) |*target| target.deinit(allocator);
    allocator.free(targets);
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
    const count = try decoder.readCount(max_regex_patterns);
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
        const atom_count = try decoder.readCount(max_regex_atoms_per_pattern);
        if (atom_count == 0) return error.CacheRegexPatternInvalid;
        total_atoms = std.math.add(
            usize,
            total_atoms,
            atom_count,
        ) catch return error.CacheRegexPatternInvalid;
        if (total_atoms > max_regex_total_atoms) {
            return error.CacheRegexPatternInvalid;
        }
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
        5 => try decodeExactNumberScalar(allocator, decoder),
        else => return error.CacheEnumScalarInvalid,
    };
}

fn decodeExactNumberScalar(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !EnumScalar {
    const text = try decoder.readBytesAlloc(
        allocator,
        4 * 1024 * 1024,
    );
    errdefer allocator.free(text);
    if (definition_core.exact_number.parse(text) == null) {
        return error.CacheNumberInvalid;
    }
    return .{ .number = text };
}

fn validateCachedRule(
    rule: CompiledRule,
    input_count: usize,
    pointer_count: usize,
) anyerror!void {
    try validateCachedRuleIndices(rule, input_count, pointer_count);
    try validateCachedBasicRule(rule);
    try validateCachedRegexRule(rule);
    try validateCachedSha256Rule(rule);
    try validateCachedPathRule(rule);
    try validateCachedComparisonRule(rule);
    try validateCachedReferenceRule(rule);
    try validateCachedProtocolRule(rule);
    try validateCachedOwnershipFields(rule);
    try validateCachedPayloadFields(rule);
    try validateCachedExtensionFields(rule);
    try validateCachedFormatParts(rule.format_parts, pointer_count, false);
    try validateCachedChildRelations(rule);
    try validateCachedReferenceRelations(rule, pointer_count);
    try validateCachedVariantRelations(rule);
    try validateCachedImportedRelations(rule);
}

fn validateCachedRuleIndices(
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
        if (rule.operator == .definition_ref) {
            if (path_id != imported_self_input and
                path_id >= input_count)
            {
                return error.CacheRuleIndexInvalid;
            }
        } else if (path_id >= pointer_count) {
            return error.CacheRuleIndexInvalid;
        }
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
        (!isNumericScalar(rule.min_number.?) or
            !isNumericScalar(rule.max_number.?) or
            exactNumberOrder(
                numericScalarValue(rule.min_number.?),
                numericScalarValue(rule.max_number.?),
            ) == .gt))
    {
        return error.InvalidRuleBounds;
    }
    if ((rule.min_number != null and
        !isNumericScalar(rule.min_number.?)) or
        (rule.max_number != null and
            !isNumericScalar(rule.max_number.?)))
    {
        return error.CacheNumberInvalid;
    }
}

fn validateCachedBasicRule(rule: CompiledRule) !void {
    if (rule.allow_bare_digest and
        rule.operator != .digest and
        rule.operator != .sha256)
    {
        return error.CacheRuleConfigurationInvalid;
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
        .bounded_number => if (rule.min_number == null and
            rule.max_number == null)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .enum_value => if (rule.values.len == 0) {
            return error.CacheRuleConfigurationInvalid;
        },
        .sorted => if (rule.pointer_id == null or rule.path_ids.len != 0) {
            return error.CacheRuleConfigurationInvalid;
        },
        else => {},
    }
}

fn validateCachedRegexRule(rule: CompiledRule) !void {
    if (rule.operator != .regex) return;
    if (rule.max_count == null or
        rule.max_count.? == 0 or
        rule.max_count.? > max_regex_subject_bytes or
        rule.regex_patterns.len == 0 or
        rule.regex_patterns.len > max_regex_patterns)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    var total_atoms: usize = 0;
    for (rule.regex_patterns) |pattern| {
        if (pattern.atoms.len == 0 or
            pattern.atoms.len > max_regex_atoms_per_pattern)
        {
            return error.CacheRuleConfigurationInvalid;
        }
        total_atoms = std.math.add(
            usize,
            total_atoms,
            pattern.atoms.len,
        ) catch return error.CacheRuleConfigurationInvalid;
        if (total_atoms > max_regex_total_atoms) {
            return error.CacheRuleConfigurationInvalid;
        }
        for (pattern.atoms) |atom| {
            if (regexByteSetEmpty(atom.bytes)) {
                return error.CacheRuleConfigurationInvalid;
            }
        }
    }
}

fn validateCachedSha256Rule(rule: CompiledRule) !void {
    if (rule.operator != .sha256) return;
    if (rule.max_count == null or
        rule.max_count.? == 0 or
        rule.max_count.? > max_sha256_subject_bytes or
        rule.other_pointer_id == null or
        rule.sha256_mode == null)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    switch (rule.sha256_mode.?) {
        .canonical_json => if (rule.path_ids.len != 0 or
            rule.sha256_prefix != null or rule.format_parts.len != 0)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .canonical_json_null => if (rule.path_ids.len != 1 or
            rule.sha256_prefix != null or rule.format_parts.len != 0)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .framed_items => if (rule.path_ids.len != 1 or
            rule.sha256_prefix == null or
            rule.sha256_prefix.?.len > 4096 or
            rule.format_parts.len == 0 or
            rule.format_parts.len > 32)
        {
            return error.CacheRuleConfigurationInvalid;
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
                .item, .value => return error.CacheRuleConfigurationInvalid,
            };
        },
    }
}

fn validateCachedPathRule(rule: CompiledRule) !void {
    switch (rule.operator) {
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
        .forbidden_object_keys => if (rule.pointer_id == null or
            rule.keys.len == 0 or
            rule.keys.len > 64 or
            rule.min_count == null or
            rule.min_count.? == 0 or
            rule.min_count.? > 128 or
            rule.max_count == null or
            rule.max_count.? == 0 or
            rule.max_count.? > 1_000_000)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        else => {},
    }
}

fn validateCachedComparisonRule(rule: CompiledRule) !void {
    switch (rule.operator) {
        .set_equality,
        .subset,
        .superset,
        .disjoint,
        .path_scope_subset,
        .path_scope_disjoint,
        .member_of,
        .not_member_of,
        .field_equal,
        .field_not_equal,
        .cross_input_equal,
        => try validateCachedComparisonPointers(rule),
        .exactly_one, .at_least_one => {
            const field_mode = rule.path_ids.len != 0 and
                rule.pointer_id == null and rule.children.len <= 64;
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
            rule.other_pointer_id == null or rule.path_ids.len != 3)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .declared_field_values => try validateCachedDeclaredValues(rule),
        else => {},
    }
}

fn validateCachedComparisonPointers(rule: CompiledRule) !void {
    if (rule.other_input_index == null or
        rule.pointer_id == null or
        rule.other_pointer_id == null)
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.path_ids.len > 1 or
        (rule.path_ids.len == 1 and
            rule.input_index != rule.other_input_index.?))
    {
        return error.CacheRuleConfigurationInvalid;
    }
}

fn validateCachedDeclaredValues(rule: CompiledRule) !void {
    if (rule.pointer_id == null or
        rule.other_pointer_id == null or
        rule.path_ids.len < 2 or
        rule.scalar_kind == null or
        (rule.scalar_kind.? != .integer and
            rule.scalar_kind.? != .number) or
        (rule.min_number == null and rule.max_number == null))
    {
        return error.CacheRuleConfigurationInvalid;
    }
}

fn validateCachedReferenceRule(rule: CompiledRule) !void {
    switch (rule.operator) {
        .reference_exists => try validateCachedReferenceShape(rule),
        .implies => try validateCachedImplication(rule),
        else => {},
    }
}

fn validateCachedReferenceShape(rule: CompiledRule) !void {
    if (rule.other_input_index == null or
        (rule.reference_sources.len == 0 and
            (rule.pointer_id == null or rule.other_pointer_id == null)) or
        (rule.reference_sources.len != 0 and
            (rule.pointer_id != null or rule.other_pointer_id != null)))
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if ((rule.reference_targets.len == 0 and
        rule.path_ids.len != 2 and rule.path_ids.len != 3) or
        (rule.reference_targets.len != 0 and
            (rule.path_ids.len != 0 or
                rule.children.len != 0 or
                rule.coverage_children.len != 0)))
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.reject_self_reference and rule.path_ids.len != 2) {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.coverage_children.len != 0 and !rule.total_coverage) {
        return error.CacheRuleConfigurationInvalid;
    }
}

fn validateCachedImplication(rule: CompiledRule) !void {
    const scalar_mode = rule.other_input_index != null and
        rule.other_pointer_id != null and rule.children.len == 0;
    const conditional_mode = rule.other_input_index == null and
        rule.other_pointer_id == null and
        rule.children.len > 0 and rule.children.len <= 64;
    const max_values: usize = if (scalar_mode) 2 else 1;
    const max_nonempty_values: usize = if (scalar_mode) 1 else 0;
    if (rule.pointer_id == null or
        (!scalar_mode and !conditional_mode) or
        rule.values.len > max_values or
        (rule.min_count != null and rule.min_count.? != 1) or
        (rule.max_count != null and rule.max_count.? != 0) or
        (rule.min_count != null and rule.max_count != null) or
        (rule.min_count != null and
            rule.values.len > max_nonempty_values) or
        (rule.max_count != null and
            rule.values.len > max_nonempty_values) or
        (rule.then_nonempty and
            (!scalar_mode or
                rule.values.len == 2 or
                ((rule.min_count != null or rule.max_count != null) and
                    rule.values.len == 1))))
    {
        return error.CacheRuleConfigurationInvalid;
    }
}

fn validateCachedProtocolRule(rule: CompiledRule) !void {
    switch (rule.operator) {
        .total_partition => if (rule.pointer_id == null or
            rule.path_ids.len < 2)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .total_mapping, .keyed_join => if (rule.pointer_id == null or
            rule.other_pointer_id == null or rule.path_ids.len != 3)
        {
            return error.CacheRuleConfigurationInvalid;
        },
        .predecessor_successor => if (rule.pointer_id == null or
            rule.other_pointer_id == null or rule.path_ids.len != 8)
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
            rule.path_ids.len != rule.imported_plan.?.inputs.len)
        {
            return error.CacheRuleConfigurationInvalid;
        } else for (rule.imported_plan.?.inputs) |input| {
            if (input.codec != .json or !input.required) {
                return error.CacheRuleConfigurationInvalid;
            }
        },
        else => {},
    }
}

fn validateCachedOwnershipFields(rule: CompiledRule) !void {
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
        rule.operator != .forbidden_object_keys and
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
}

fn validateCachedPayloadFields(rule: CompiledRule) !void {
    if (rule.operator != .exact_object and
        rule.operator != .safe_relative_path and
        rule.operator != .forbidden_object_keys and
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
    if (!operatorOwnsChildren(rule.operator) and rule.children.len != 0) {
        return error.CacheRuleConfigurationInvalid;
    }
}

fn operatorOwnsChildren(operator: definition.Operator) bool {
    return switch (operator) {
        .optional_field,
        .one_of,
        .all_rules,
        .any_rules,
        .no_rules,
        .object_values,
        .reference_exists,
        .keyed_join,
        .exactly_one,
        .at_least_one,
        .implies,
        => true,
        else => false,
    };
}

fn validateCachedExtensionFields(rule: CompiledRule) !void {
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
        (rule.ignore_null_references or
            rule.coverage_children.len != 0 or
            rule.reference_targets.len != 0))
    {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .implies and rule.then_nonempty) {
        return error.CacheRuleConfigurationInvalid;
    }
    if (rule.operator != .reference_exists and
        rule.operator != .keyed_unique and
        rule.reference_sources.len != 0)
    {
        return error.CacheRuleConfigurationInvalid;
    }
}

fn validateCachedChildRelations(rule: CompiledRule) !void {
    for (rule.children) |*child| {
        if (rule.operator == .implies) {
            if (!isValidationOperator(child.operator)) {
                return error.CacheRuleConfigurationInvalid;
            }
        } else if (child.input_index != rule.input_index or
            !isItemOperator(child.operator))
        {
            return error.CacheRuleConfigurationInvalid;
        }
    }
    for (rule.coverage_children) |child| {
        if (child.input_index != rule.other_input_index.? or
            !isItemOperator(child.operator))
        {
            return error.CacheRuleConfigurationInvalid;
        }
    }
}

fn validateCachedReferenceRelations(
    rule: CompiledRule,
    pointer_count: usize,
) anyerror!void {
    for (rule.reference_targets) |target| {
        try validateCachedReferenceTarget(
            target,
            rule.other_input_index.?,
            rule.total_coverage,
            pointer_count,
        );
    }
    for (rule.reference_sources) |source| {
        if (source.pointer_id >= pointer_count or
            source.reference_pointer_id >= pointer_count or
            (source.items_pointer_id != null and
                source.items_pointer_id.? >= pointer_count) or
            (source.singleton and source.items_pointer_id != null))
        {
            return error.CacheRuleIndexInvalid;
        }
        try validateCachedFormatParts(
            source.format_parts,
            pointer_count,
            true,
        );
        try validateCachedItemRuleGroup(source.rules, rule.input_index);
    }
}

fn validateCachedVariantRelations(rule: CompiledRule) !void {
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
        try validateCachedItemRuleGroup(variant.rules, rule.input_index);
    }
}

fn validateCachedImportedRelations(rule: CompiledRule) !void {
    const imported_plan = rule.imported_plan orelse return;
    var self_count: usize = 0;
    for (rule.path_ids) |binding| {
        self_count += @intFromBool(binding == imported_self_input);
    }
    if (self_count != 1) return error.CacheRuleConfigurationInvalid;
    for (imported_plan.rules) |imported_rule| {
        if (!isValidationOperator(imported_rule.operator)) {
            return error.CacheRuleConfigurationInvalid;
        }
    }
}

fn validateCachedReferenceTarget(
    target: CompiledReferenceTarget,
    input_index: u8,
    total_coverage: bool,
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
    try validateCachedItemRuleGroup(target.rules, input_index);
    try validateCachedItemRuleGroup(target.match_rules, input_index);
    try validateCachedItemRuleGroup(target.coverage_rules, input_index);
}

fn validateCachedItemRuleGroup(
    rules: []const CompiledRule,
    input_index: u8,
) !void {
    for (rules) |*rule| {
        if (rule.input_index != input_index or
            !isItemOperator(rule.operator))
        {
            return error.CacheRuleConfigurationInvalid;
        }
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
        .number => |text| {
            try encoder.writeByte(5);
            try encoder.writeBytes(text);
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

fn writeOptionalEnumScalar(
    encoder: *definition_core.cache.Encoder,
    value: ?EnumScalar,
) !void {
    try encoder.writeBool(value != null);
    if (value) |scalar| try encodeEnumScalar(encoder, scalar);
}

fn readOptionalEnumScalar(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !?EnumScalar {
    if (!try decoder.readBool()) return null;
    const value = try decodeEnumScalar(allocator, decoder);
    if (!isNumericScalar(value)) {
        var owned = value;
        owned.deinit(allocator);
        return error.CacheNumberInvalid;
    }
    return value;
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

fn normalizeParsedNumbers(
    backing_allocator: std.mem.Allocator,
    root: *std.json.Value,
) !void {
    var pending = std.heap.stackFallback(
        4096,
        backing_allocator,
    );
    const allocator = pending.get();
    var values: std.ArrayList(*std.json.Value) = .empty;
    defer values.deinit(allocator);
    try values.append(allocator, root);
    while (values.pop()) |value| {
        switch (value.*) {
            .number_string => |text| {
                if (exactIntegerFromNumberString(text)) |integer| {
                    value.* = .{ .integer = integer };
                    continue;
                }
                const parsed = std.json.Value.parseFromNumberSlice(text);
                if (parsed != .number_string and exactNumbersEqual(
                    .{ .number_string = text },
                    parsed,
                )) value.* = parsed;
            },
            .array => |*array| {
                for (array.items) |*item| {
                    try values.append(allocator, item);
                }
            },
            .object => |*object| {
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    try values.append(
                        allocator,
                        entry.value_ptr,
                    );
                }
            },
            else => {},
        }
    }
}

fn exactIntegerFromNumberString(text: []const u8) ?i64 {
    const number = definition_core.exact_number.parse(text) orelse return null;
    return definition_core.exact_number.toI64(number);
}

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
    return executeInternal(
        allocator,
        validation_plan,
        documents,
        true,
    );
}

pub fn executeValidationOnly(
    allocator: std.mem.Allocator,
    validation_plan: *const Plan,
    documents: []const InputDocument,
) !Execution {
    return executeInternal(
        allocator,
        validation_plan,
        documents,
        false,
    );
}

fn executeInternal(
    allocator: std.mem.Allocator,
    validation_plan: *const Plan,
    documents: []const InputDocument,
    normalize_numbers: bool,
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
        try loadInputDocument(
            allocator,
            validation_plan,
            document,
            loaded,
            seen,
            &total_bytes,
            &digests,
            &diagnostics,
        );
    }
    try addMissingInputDiagnostics(validation_plan, seen, &diagnostics);
    try applyRules(
        allocator,
        validation_plan,
        loaded,
        validation_plan.rules,
        &diagnostics,
    );
    if (normalize_numbers) try normalizeLoadedNumbers(allocator, loaded);
    std.sort.heap(InputDigest, digests.items, {}, struct {
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

fn normalizeLoadedNumbers(
    allocator: std.mem.Allocator,
    loaded: []LoadedInput,
) !void {
    for (loaded) |*input| {
        if (input.parsed_json) |*parsed| {
            try normalizeParsedNumbers(
                allocator,
                &parsed.value,
            );
        }
    }
}

fn loadInputDocument(
    allocator: std.mem.Allocator,
    validation_plan: *const Plan,
    document: InputDocument,
    loaded: []LoadedInput,
    seen: []bool,
    total_bytes: *usize,
    digests: *std.ArrayList(InputDigest),
    diagnostics: *definition_core.diagnostics.Collector,
) !void {
    const input_index = findInput(
        validation_plan.inputs,
        document.name,
    ) orelse return error.UnknownInputBinding;
    if (seen[input_index]) return error.DuplicateInputBinding;
    seen[input_index] = true;
    total_bytes.* = std.math.add(
        usize,
        total_bytes.*,
        document.bytes.len,
    ) catch return error.InputBytesExceeded;
    if (document.bytes.len > validation_plan.inputs[input_index].max_bytes or
        total_bytes.* > validation_plan.max_input_bytes)
    {
        try diagnostics.add(
            "artifact.input-too-large",
            document.name,
            "input exceeds its declared byte bound",
        );
        return;
    }
    loaded[input_index].bytes = document.bytes;
    try appendInputDigest(allocator, document, digests);
    try parseLoadedInput(
        allocator,
        validation_plan,
        document,
        input_index,
        loaded,
        diagnostics,
    );
}

fn appendInputDigest(
    allocator: std.mem.Allocator,
    document: InputDocument,
    digests: *std.ArrayList(InputDigest),
) !void {
    const name = try allocator.dupe(u8, document.name);
    errdefer allocator.free(name);
    const digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        document.bytes,
    );
    errdefer allocator.free(digest);
    try digests.append(allocator, .{ .name = name, .digest = digest });
}

fn parseLoadedInput(
    allocator: std.mem.Allocator,
    validation_plan: *const Plan,
    document: InputDocument,
    input_index: usize,
    loaded: []LoadedInput,
    diagnostics: *definition_core.diagnostics.Collector,
) !void {
    switch (validation_plan.inputs[input_index].codec) {
        .json => loaded[input_index].parsed_json = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            document.bytes,
            .{
                .allocate = .alloc_if_needed,
                .duplicate_field_behavior = .@"error",
                .parse_numbers = false,
            },
        ) catch {
            try diagnostics.add(
                "artifact.invalid-json",
                document.name,
                "input is not duplicate-free JSON",
            );
            return;
        },
        .jsonl => try validateJsonl(
            allocator,
            document.name,
            document.bytes,
            validation_plan.max_records,
            diagnostics,
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

fn addMissingInputDiagnostics(
    validation_plan: *const Plan,
    seen: []const bool,
    diagnostics: *definition_core.diagnostics.Collector,
) !void {
    for (validation_plan.inputs, 0..) |input, index| {
        if (input.required and !seen[index]) {
            try diagnostics.add(
                "artifact.missing-input",
                input.name,
                "required input was not supplied",
            );
        }
    }
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
    try addMissingInputDiagnostics(validation_plan, seen, &diagnostics);
    try applyRules(
        allocator,
        validation_plan,
        loaded,
        validation_plan.rules,
        &diagnostics,
    );
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

fn applyRules(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    loaded: []const LoadedInput,
    rules: []const CompiledRule,
    diagnostics: *definition_core.diagnostics.Collector,
) !void {
    const RuleFrame = struct {
        rules: []const CompiledRule,
        next_index: usize = 0,
    };
    var stack: [17]RuleFrame = undefined;
    var stack_len: usize = 1;
    var pointer_ancestors: [1025]?std.json.Value = undefined;
    if (plan.max_root_pointer_depth >= pointer_ancestors.len) {
        return error.JsonPointerTooDeep;
    }
    stack[0] = .{ .rules = rules };
    while (stack_len != 0) {
        const frame = &stack[stack_len - 1];
        if (frame.next_index == frame.rules.len) {
            stack_len -= 1;
            continue;
        }
        const rule_index = frame.next_index;
        const rule = &frame.rules[rule_index];
        frame.next_index += 1;
        if (rule.operator == .implies and rule.children.len != 0) {
            const root = loaded[rule.input_index].json() orelse continue;
            if (implicationPredicateHolds(plan, root, rule)) {
                if (stack_len == stack.len) {
                    return error.ConditionalRuleDepthExceeded;
                }
                stack[stack_len] = .{ .rules = rule.children };
                stack_len += 1;
            }
            continue;
        }
        if (stack_len == 1) {
            try applyRootRule(
                allocator,
                plan,
                loaded,
                rule,
                rule_index,
                &pointer_ancestors,
                diagnostics,
            );
        } else {
            try applyRule(
                allocator,
                plan,
                loaded,
                rule,
                diagnostics,
            );
        }
    }
}

fn applyRootRule(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    loaded: []const LoadedInput,
    rule: *const CompiledRule,
    rule_index: usize,
    pointer_ancestors: *[1025]?std.json.Value,
    diagnostics: *definition_core.diagnostics.Collector,
) !void {
    const root = loaded[rule.input_index].json() orelse return;
    const target = if (rule.pointer_id) |pointer_id| blk: {
        const pointer = plan.pointers[pointer_id];
        if (pointer.segments.len >= pointer_ancestors.len) {
            return error.JsonPointerTooDeep;
        }
        const shared_prefix = plan.root_shared_prefixes[rule_index];
        pointer_ancestors[0] = root;
        var current = pointer_ancestors[shared_prefix];
        for (
            pointer.segments[shared_prefix..],
            shared_prefix + 1..,
        ) |segment, depth| {
            current = if (current) |parent|
                resolvePointerSegment(parent, segment)
            else
                null;
            pointer_ancestors[depth] = current;
        }
        break :blk current;
    } else blk: {
        pointer_ancestors[0] = root;
        break :blk root;
    };
    try applyResolvedRule(
        allocator,
        plan,
        loaded,
        rule,
        root,
        target,
        diagnostics,
    );
}

fn commonPointerDepth(left: Pointer, right: Pointer) usize {
    const maximum = @min(left.segments.len, right.segments.len);
    var depth: usize = 0;
    while (depth < maximum and
        std.mem.eql(u8, left.segments[depth], right.segments[depth])) : (depth += 1)
    {}
    return depth;
}

fn resolvePointerSegment(
    parent: std.json.Value,
    segment: []const u8,
) ?std.json.Value {
    return switch (parent) {
        .object => |object| object.get(segment),
        .array => |array| blk: {
            if (segment.len == 0 or
                (segment.len > 1 and segment[0] == '0'))
            {
                break :blk null;
            }
            const index = std.fmt.parseInt(
                usize,
                segment,
                10,
            ) catch break :blk null;
            break :blk if (index < array.items.len)
                array.items[index]
            else
                null;
        },
        else => null,
    };
}

fn applyRule(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    loaded: []const LoadedInput,
    rule: *const CompiledRule,
    diagnostics: *definition_core.diagnostics.Collector,
) !void {
    const root = loaded[rule.input_index].json() orelse return;
    const target = if (rule.pointer_id) |pointer_id|
        resolve(root, plan.pointers[pointer_id])
    else
        root;
    return applyResolvedRule(
        allocator,
        plan,
        loaded,
        rule,
        root,
        target,
        diagnostics,
    );
}

fn applyResolvedRule(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    loaded: []const LoadedInput,
    rule: *const CompiledRule,
    root: std.json.Value,
    target: ?std.json.Value,
    diagnostics: *definition_core.diagnostics.Collector,
) !void {
    const path = if (rule.pointer_id) |pointer_id| plan.pointers[pointer_id].raw else "";
    const valid = (try evaluateRule(.{
        .allocator = allocator,
        .plan = plan,
        .loaded = loaded,
        .rule = rule,
        .root = root,
        .target = target,
    })) orelse return;
    if (!valid) {
        try diagnostics.add(
            rule.operator.id(),
            path,
            "artifact does not satisfy the compiled structural rule",
        );
    }
}

const RuleEvaluationContext = struct {
    allocator: std.mem.Allocator,
    plan: *const Plan,
    loaded: []const LoadedInput,
    rule: *const CompiledRule,
    root: std.json.Value,
    target: ?std.json.Value,
};

inline fn evaluateRule(context: RuleEvaluationContext) anyerror!?bool {
    return switch (context.rule.operator) {
        .required_field,
        .field_absent,
        .optional_field,
        .exact_object,
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
        .forbidden_object_keys,
        .unique,
        .sorted,
        => try evaluatePrimitiveRule(context),
        .keyed_unique,
        .keyed_join,
        .declared_field_values,
        .reference_exists,
        .implies,
        => try evaluateIndexedRule(context),
        .total_partition,
        .total_mapping,
        .predecessor_successor,
        .path_format,
        => try evaluateProtocolRule(context),
        else => try evaluateCompositeRule(context),
    };
}

inline fn evaluatePrimitiveRule(context: RuleEvaluationContext) anyerror!bool {
    const rule = context.rule;
    const target = context.target;
    return switch (rule.operator) {
        .required_field => target != null,
        .field_absent => target == null,
        .optional_field => if (target) |value|
            (rule.allow_null and value == .null) or
                rule.children.len == 0 or
                try itemRulesHold(
                    context.allocator,
                    context.plan,
                    rule.children,
                    value,
                )
        else
            true,
        .exact_object => if (target) |value| exactObject(value, rule) else false,
        .scalar_type => if (target) |value|
            valueHasKind(value, rule.scalar_kind.?)
        else
            false,
        .bounded_string => if (target) |value| boundedString(value, rule) else false,
        .regex => if (target) |value| regexHolds(value, rule) else false,
        .sha256 => if (target) |value|
            try sha256Holds(
                context.allocator,
                context.plan,
                context.loaded,
                rule,
                value,
            )
        else
            false,
        .bounded_number => if (target) |value| boundedNumber(value, rule) else false,
        .bounded_array => if (target) |value|
            boundedCount(value, .array, rule)
        else
            false,
        .bounded_object => if (target) |value|
            boundedCount(value, .object, rule)
        else
            false,
        .enum_value => if (target) |value| enumContains(rule.values, value) else false,
        .digest => if (target) |value|
            digestHolds(value, rule.allow_bare_digest)
        else
            false,
        .timestamp => if (target) |value|
            validateScalar(value, .timestamp)
        else
            false,
        .safe_identifier => if (target) |value| safeIdentifier(value, rule) else false,
        .safe_relative_path => if (target) |value|
            safeRelativePath(value, rule)
        else
            false,
        .forbidden_object_keys => if (target) |value|
            try forbiddenObjectKeysHold(context.allocator, value, rule)
        else
            false,
        .unique => if (target) |value| arrayUnique(value) else false,
        .sorted => if (target) |value|
            arraySorted(value, if (rule.other_pointer_id) |pointer_id|
                context.plan.pointers[pointer_id]
            else
                null)
        else
            false,
        else => unreachable,
    };
}

inline fn evaluateIndexedRule(context: RuleEvaluationContext) anyerror!?bool {
    const rule = context.rule;
    return switch (rule.operator) {
        .keyed_unique => if (rule.reference_sources.len == 0)
            if (context.target) |value|
                try keyedUnique(
                    context.allocator,
                    value,
                    context.plan.pointers[rule.other_pointer_id.?],
                    context.plan.max_records,
                )
            else
                false
        else
            try keyedUniqueSources(
                context.allocator,
                context.plan,
                context.root,
                rule,
            ),
        .keyed_join => try selectedKeyedJoin(
            context.allocator,
            context.plan,
            context.root,
            rule,
        ),
        .declared_field_values => if (context.target) |value|
            try declaredFieldValuesHold(
                context.allocator,
                context.plan,
                context.root,
                rule,
                value,
            )
        else
            false,
        .reference_exists => if (context.target) |value|
            try referencesExist(
                context.allocator,
                context.plan,
                rule,
                value,
                context.root,
                context.loaded[rule.other_input_index.?].json() orelse
                    return null,
            )
        else
            false,
        .implies => implicationHolds(
            context.plan,
            context.root,
            context.loaded[rule.other_input_index.?].json() orelse
                return null,
            rule,
        ),
        else => unreachable,
    };
}

inline fn evaluateProtocolRule(context: RuleEvaluationContext) anyerror!bool {
    const rule = context.rule;
    return switch (rule.operator) {
        .total_partition => try totalPartition(
            context.allocator,
            context.plan,
            context.root,
            rule,
        ),
        .total_mapping => try totalMapping(
            context.allocator,
            context.plan,
            context.root,
            rule,
        ),
        .predecessor_successor => try predecessorSuccessorHolds(
            context.allocator,
            context.plan,
            context.root,
            rule,
        ),
        .path_format => if (context.target) |value|
            formattedFieldsHold(context.plan, rule, value)
        else
            false,
        else => unreachable,
    };
}

inline fn evaluateCompositeRule(context: RuleEvaluationContext) anyerror!bool {
    const rule = context.rule;
    return switch (rule.operator) {
        .one_of => if (context.target) |value|
            try oneOfRulesHold(context.allocator, context.plan, rule, value)
        else
            false,
        .tagged_union => if (context.target) |value|
            try taggedUnionHolds(context.allocator, context.plan, rule, value)
        else
            false,
        .definition_ref => if (context.target) |value|
            try importedPlanHolds(
                context.allocator,
                rule.imported_plan.?,
                rule.path_ids,
                context.loaded,
                value,
            )
        else
            false,
        .all_rules, .any_rules, .no_rules => if (context.target) |value|
            try collectionRuleHolds(
                context.allocator,
                context.plan,
                rule,
                value,
            )
        else
            false,
        .object_values => if (context.target) |value|
            try objectValuesHold(context.allocator, context.plan, rule, value)
        else
            false,
        .set_equality,
        .subset,
        .superset,
        .disjoint,
        .path_scope_subset,
        .path_scope_disjoint,
        .member_of,
        .not_member_of,
        .field_equal,
        .field_not_equal,
        .cross_input_equal,
        => compareRule(context.plan, context.loaded, rule),
        .exactly_one, .at_least_one => if (rule.path_ids.len != 0)
            if (rule.children.len == 0)
                countPresent(context.plan, context.root, rule)
            else
                try countMatchingFields(
                    context.allocator,
                    context.plan,
                    context.root,
                    rule,
                )
        else
            try countMatching(
                context.allocator,
                context.plan,
                context.root,
                rule,
            ),
        else => true,
    };
}

fn collectionRuleHolds(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: *const CompiledRule,
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
    rule: *const CompiledRule,
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

fn forbiddenObjectKeysHold(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    rule: *const CompiledRule,
) !bool {
    var pending: std.ArrayList(ForbiddenValueTask) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, .{ .value = value, .depth = 0 });
    var visited: usize = 0;
    while (pending.pop()) |task| {
        if (task.depth > rule.min_count.?) return false;
        visited = std.math.add(usize, visited, 1) catch return false;
        if (visited > rule.max_count.?) return false;
        if (!try inspectForbiddenValue(
            allocator,
            &pending,
            task,
            rule,
            visited,
        )) return false;
    }
    return true;
}

const ForbiddenValueTask = struct {
    value: std.json.Value,
    depth: usize,
};

fn inspectForbiddenValue(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(ForbiddenValueTask),
    task: ForbiddenValueTask,
    rule: *const CompiledRule,
    visited: usize,
) !bool {
    switch (task.value) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (forbiddenKeyMatches(entry.key_ptr.*, rule)) return false;
                if (!try pushForbiddenValue(
                    allocator,
                    pending,
                    entry.value_ptr.*,
                    task.depth + 1,
                    rule,
                    visited,
                )) {
                    return false;
                }
            }
        },
        .array => |array| for (array.items) |item| {
            if (!try pushForbiddenValue(
                allocator,
                pending,
                item,
                task.depth + 1,
                rule,
                visited,
            )) {
                return false;
            }
        },
        else => {},
    }
    return true;
}

fn pushForbiddenValue(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(ForbiddenValueTask),
    value: std.json.Value,
    depth: usize,
    rule: *const CompiledRule,
    visited: usize,
) !bool {
    if (depth > rule.min_count.?) return false;
    const scheduled = std.math.add(
        usize,
        visited,
        pending.items.len,
    ) catch return false;
    if (scheduled >= rule.max_count.?) return false;
    try pending.append(allocator, .{ .value = value, .depth = depth });
    return true;
}

fn forbiddenKeyMatches(key: []const u8, rule: *const CompiledRule) bool {
    for (rule.keys) |forbidden| {
        const matches = if (rule.case_insensitive)
            std.ascii.eqlIgnoreCase(key, forbidden)
        else
            std.mem.eql(u8, key, forbidden);
        if (matches) return true;
    }
    return false;
}

fn oneOfRulesHold(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: *const CompiledRule,
    value: std.json.Value,
) anyerror!bool {
    var matches: usize = 0;
    for (rule.children) |*child| {
        if (try itemRuleHolds(allocator, plan, child, value)) {
            matches += 1;
            if (matches > 1) return false;
        }
    }
    return matches == 1;
}

fn formattedFieldsHold(
    plan: *const Plan,
    rule: *const CompiledRule,
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
            if (!formattedItemTargetHolds(plan, rule, parent, item)) {
                return false;
            }
        }
    }
    return true;
}

fn formattedItemTargetHolds(
    plan: *const Plan,
    rule: *const CompiledRule,
    parent: std.json.Value,
    item: std.json.Value,
) bool {
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
        const fragment = formattedFieldFragment(
            plan,
            part,
            parent,
            item,
        ) orelse return false;
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
    return offset == target.len;
}

fn formattedFieldFragment(
    plan: *const Plan,
    part: CompiledFormatPart,
    parent: std.json.Value,
    item: std.json.Value,
) ?[]const u8 {
    return switch (part) {
        .literal => |literal| literal,
        .parent => |pointer_id| switch (resolve(
            parent,
            plan.pointers[pointer_id],
        ) orelse return null) {
            .string => |text| text,
            else => null,
        },
        .item => |pointer_id| switch (resolve(
            item,
            plan.pointers[pointer_id],
        ) orelse return null) {
            .string => |text| text,
            else => null,
        },
        .value => null,
    };
}

fn taggedUnionHolds(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: *const CompiledRule,
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
    for (rules) |*rule| {
        if (!try itemRuleHolds(allocator, plan, rule, root)) return false;
    }
    return true;
}

fn itemRuleHolds(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: *const CompiledRule,
    root: std.json.Value,
) anyerror!bool {
    const target = if (rule.pointer_id) |pointer_id|
        resolve(root, plan.pointers[pointer_id])
    else
        root;
    const context: RuleEvaluationContext = .{
        .allocator = allocator,
        .plan = plan,
        .loaded = &.{},
        .rule = rule,
        .root = root,
        .target = target,
    };
    if (isPrimitiveExecutionOperator(rule.operator)) {
        return evaluatePrimitiveRule(context);
    }
    if (isIndexedExecutionOperator(rule.operator)) {
        return evaluateIndexedItemRule(context);
    }
    if (isProtocolExecutionOperator(rule.operator)) {
        return evaluateProtocolRule(context);
    }
    return evaluateCompositeItemRule(context);
}

fn evaluateIndexedItemRule(
    context: RuleEvaluationContext,
) anyerror!bool {
    const rule = context.rule;
    return switch (rule.operator) {
        .keyed_unique => if (rule.reference_sources.len == 0)
            if (context.target) |value|
                try keyedUnique(
                    context.allocator,
                    value,
                    context.plan.pointers[rule.other_pointer_id.?],
                    context.plan.max_records,
                )
            else
                false
        else
            try keyedUniqueSources(
                context.allocator,
                context.plan,
                context.root,
                rule,
            ),
        .keyed_join => try selectedKeyedJoin(
            context.allocator,
            context.plan,
            context.root,
            rule,
        ),
        .declared_field_values => if (context.target) |value|
            try declaredFieldValuesHold(
                context.allocator,
                context.plan,
                context.root,
                rule,
                value,
            )
        else
            false,
        .reference_exists => if (context.target) |value|
            try referencesExist(
                context.allocator,
                context.plan,
                rule,
                value,
                context.root,
                context.root,
            )
        else
            false,
        .implies => if (rule.children.len != 0)
            if (implicationPredicateHolds(context.plan, context.root, rule))
                itemRulesHold(
                    context.allocator,
                    context.plan,
                    rule.children,
                    context.root,
                )
            else
                true
        else
            implicationHolds(
                context.plan,
                context.root,
                context.root,
                rule,
            ),
        else => unreachable,
    };
}

fn evaluateCompositeItemRule(
    context: RuleEvaluationContext,
) anyerror!bool {
    if (isComparisonExecutionOperator(context.rule.operator)) {
        return compareRuleRoots(
            context.plan,
            context.rule,
            context.root,
            context.root,
        );
    }
    return evaluateCompositeRule(context);
}

fn isPrimitiveExecutionOperator(operator: definition.Operator) bool {
    return switch (operator) {
        .required_field,
        .field_absent,
        .optional_field,
        .exact_object,
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
        .forbidden_object_keys,
        .unique,
        .sorted,
        => true,
        else => false,
    };
}

fn isIndexedExecutionOperator(operator: definition.Operator) bool {
    return switch (operator) {
        .keyed_unique,
        .keyed_join,
        .declared_field_values,
        .reference_exists,
        .implies,
        => true,
        else => false,
    };
}

fn isProtocolExecutionOperator(operator: definition.Operator) bool {
    return switch (operator) {
        .total_partition,
        .total_mapping,
        .predecessor_successor,
        .path_format,
        => true,
        else => false,
    };
}

fn isComparisonExecutionOperator(operator: definition.Operator) bool {
    return switch (operator) {
        .set_equality,
        .subset,
        .superset,
        .disjoint,
        .path_scope_subset,
        .path_scope_disjoint,
        .member_of,
        .not_member_of,
        .field_equal,
        .field_not_equal,
        .cross_input_equal,
        => true,
        else => false,
    };
}
fn importedPlanHolds(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    bindings: []const u16,
    outer_loaded: []const LoadedInput,
    target: std.json.Value,
) anyerror!bool {
    if (bindings.len != plan.inputs.len) {
        return error.ImportedDefinitionInputBindingsMismatch;
    }
    const values = try allocator.alloc(InputValue, plan.inputs.len);
    defer allocator.free(values);
    for (plan.inputs, bindings, values) |input, binding, *value| {
        value.* = .{
            .name = input.name,
            .value = if (binding == imported_self_input)
                target
            else if (binding < outer_loaded.len)
                outer_loaded[binding].json() orelse return false
            else
                return error.ImportedDefinitionInputBindingInvalid,
        };
    }
    var execution = try executeValues(allocator, plan, values);
    defer execution.deinit();
    return execution.isValid();
}

fn compareRule(
    plan: *const Plan,
    loaded: []const LoadedInput,
    rule: *const CompiledRule,
) bool {
    const left_root = loaded[rule.input_index].json() orelse return false;
    const right_root = loaded[rule.other_input_index.?].json() orelse return false;
    return compareRuleRoots(plan, rule, left_root, right_root);
}

fn compareRuleRoots(
    plan: *const Plan,
    rule: *const CompiledRule,
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
        .not_member_of => !valueMemberOf(left, right, max_records),
        else => false,
    };
}

fn countPresent(plan: *const Plan, root: std.json.Value, rule: *const CompiledRule) bool {
    var count: usize = 0;
    for (rule.path_ids) |pointer_id| {
        if (resolve(root, plan.pointers[pointer_id]) != null) count += 1;
    }
    return if (rule.operator == .exactly_one) count == 1 else count >= 1;
}

fn countMatchingFields(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
    rule: *const CompiledRule,
) !bool {
    var count: usize = 0;
    for (rule.path_ids) |pointer_id| {
        const value = resolve(root, plan.pointers[pointer_id]) orelse continue;
        if (try itemRulesHold(allocator, plan, rule.children, value)) {
            count += 1;
            if (rule.operator == .exactly_one and count > 1) return false;
            if (rule.operator == .at_least_one) return true;
        }
    }
    return count == 1;
}

fn countMatching(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
    rule: *const CompiledRule,
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
    rule: *const CompiledRule,
) bool {
    if (!implicationPredicateHolds(plan, condition_root, rule)) return true;
    const consequent = resolve(
        consequent_root,
        plan.pointers[rule.other_pointer_id.?],
    ) orelse return false;
    const expected_consequent = if (rule.min_count != null or
        rule.max_count != null)
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

fn implicationPredicateHolds(
    plan: *const Plan,
    condition_root: std.json.Value,
    rule: *const CompiledRule,
) bool {
    const condition = resolve(
        condition_root,
        plan.pointers[rule.pointer_id.?],
    ) orelse return false;
    if (rule.min_count == null and rule.values.len >= 1 and
        !enumEqual(rule.values[0], condition))
    {
        return false;
    }
    if (rule.min_count != null) return valueNonempty(condition);
    if (rule.max_count != null) return !valueNonempty(condition);
    return true;
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
    rule: *const CompiledRule,
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

const MappingCollections = struct {
    sources: []const std.json.Value,
    targets: []const std.json.Value,
    mappings: []const std.json.Value,
};

fn totalMapping(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
    rule: *const CompiledRule,
) !bool {
    const collections = resolveMappingCollections(
        plan,
        root,
        rule,
    ) orelse return false;

    var source_index: std.AutoHashMapUnmanaged(
        [32]u8,
        MappingSource,
    ) = .empty;
    defer source_index.deinit(allocator);
    if (!try indexMappingSources(
        allocator,
        collections.sources,
        &source_index,
    )) return false;

    var target_index: std.AutoHashMapUnmanaged(
        [32]u8,
        std.json.Value,
    ) = .empty;
    defer target_index.deinit(allocator);
    if (!try indexMappingTargets(
        allocator,
        collections.targets,
        &target_index,
    )) return false;
    if (!try mappingsHold(
        collections.mappings,
        plan,
        rule,
        &source_index,
        &target_index,
    )) return false;
    var iterator = source_index.valueIterator();
    while (iterator.next()) |source| {
        if (!source.mapped) return false;
    }
    return true;
}

fn resolveMappingCollections(
    plan: *const Plan,
    root: std.json.Value,
    rule: *const CompiledRule,
) ?MappingCollections {
    const sources = switch (resolve(
        root,
        plan.pointers[rule.pointer_id.?],
    ) orelse return null) {
        .array => |array| array.items,
        else => return null,
    };
    const targets = switch (resolve(
        root,
        plan.pointers[rule.other_pointer_id.?],
    ) orelse return null) {
        .array => |array| array.items,
        else => return null,
    };
    const mappings = switch (resolve(
        root,
        plan.pointers[rule.path_ids[0]],
    ) orelse return null) {
        .array => |array| array.items,
        else => return null,
    };
    if (sources.len > plan.max_records or
        targets.len > plan.max_records or
        mappings.len > plan.max_records or
        mappings.len != sources.len)
    {
        return null;
    }
    return .{
        .sources = sources,
        .targets = targets,
        .mappings = mappings,
    };
}

fn indexMappingSources(
    allocator: std.mem.Allocator,
    sources: []const std.json.Value,
    index: *std.AutoHashMapUnmanaged([32]u8, MappingSource),
) !bool {
    for (sources) |value| {
        const digest = scalarKeyDigest(value) orelse return false;
        const result = try index.getOrPut(allocator, digest);
        if (result.found_existing) {
            if (!valuesEqual(result.value_ptr.value, value)) {
                return error.TotalMappingDigestCollision;
            }
            return false;
        }
        result.value_ptr.* = .{ .value = value };
    }
    return true;
}

fn indexMappingTargets(
    allocator: std.mem.Allocator,
    targets: []const std.json.Value,
    index: *std.AutoHashMapUnmanaged([32]u8, std.json.Value),
) !bool {
    for (targets) |value| {
        const digest = scalarKeyDigest(value) orelse return false;
        const result = try index.getOrPut(allocator, digest);
        if (result.found_existing) {
            if (!valuesEqual(result.value_ptr.*, value)) {
                return error.TotalMappingDigestCollision;
            }
            return false;
        }
        result.value_ptr.* = value;
    }
    return true;
}

fn mappingsHold(
    mappings: []const std.json.Value,
    plan: *const Plan,
    rule: *const CompiledRule,
    source_index: *std.AutoHashMapUnmanaged([32]u8, MappingSource),
    target_index: *std.AutoHashMapUnmanaged([32]u8, std.json.Value),
) !bool {
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
    return true;
}

fn resolve(root: std.json.Value, pointer: Pointer) ?std.json.Value {
    return definition_core.json_pointer.lookup(root, pointer);
}

fn exactObject(value: std.json.Value, rule: *const CompiledRule) bool {
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
        .integer => value == .integer or
            (value == .number_string and
                std.json.Scanner.isNumberFormattedLikeAnInteger(
                    value.number_string,
                )),
        .number => value == .integer or value == .float or value == .number_string,
        .boolean => value == .bool,
        .array => value == .array,
        .object => value == .object,
        .null => value == .null,
    };
}

fn boundedString(value: std.json.Value, rule: *const CompiledRule) bool {
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

fn regexHolds(value: std.json.Value, rule: *const CompiledRule) bool {
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
    loaded: []const LoadedInput,
    rule: *const CompiledRule,
    value: std.json.Value,
) !bool {
    if (plan.pointers[rule.other_pointer_id.?].raw.len == 0) return false;
    const expected_root = if (rule.other_input_index) |input_index|
        loaded[input_index].json() orelse return false
    else
        value;
    const expected_value = resolve(
        expected_root,
        plan.pointers[rule.other_pointer_id.?],
    ) orelse return false;
    const expected = switch (expected_value) {
        .string => |text| text,
        else => return false,
    };
    if (!digestHolds(expected_value, rule.allow_bare_digest)) return false;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    switch (rule.sha256_mode.?) {
        .canonical_json => if (!try hashCanonicalJson(
            allocator,
            rule,
            value,
            &hasher,
        )) return false,
        .canonical_json_null => if (!try hashCanonicalJsonNull(
            allocator,
            plan,
            rule,
            value,
            &hasher,
        )) return false,
        .framed_items => if (!hashFramedItems(
            plan,
            rule,
            value,
            &hasher,
        )) return false,
        .framed_fields => if (!hashFramedFields(
            plan,
            rule,
            value,
            &hasher,
        )) return false,
    }
    return sha256FinalMatches(
        &hasher,
        expected,
        rule.allow_bare_digest,
    );
}

fn hashCanonicalJson(
    allocator: std.mem.Allocator,
    rule: *const CompiledRule,
    value: std.json.Value,
    hasher: *std.crypto.hash.sha2.Sha256,
) !bool {
    const canonical = definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        value,
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(canonical);
    if (canonical.len > rule.max_count.?) return false;
    hasher.update(canonical);
    return true;
}

fn hashCanonicalJsonNull(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: *const CompiledRule,
    value: std.json.Value,
    hasher: *std.crypto.hash.sha2.Sha256,
) !bool {
    if (plan.pointers[rule.path_ids[0]].raw.len == 0) return false;
    var mutable = value;
    const null_field = definition_core.json_pointer.lookupPtr(
        &mutable,
        plan.pointers[rule.path_ids[0]],
    ) orelse return false;
    const preserved = null_field.*;
    defer null_field.* = preserved;
    null_field.* = .null;
    const canonical = definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        mutable,
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(canonical);
    if (canonical.len > rule.max_count.?) return false;
    hasher.update(canonical);
    return true;
}

fn hashFramedItems(
    plan: *const Plan,
    rule: *const CompiledRule,
    value: std.json.Value,
    hasher: *std.crypto.hash.sha2.Sha256,
) bool {
    if (plan.pointers[rule.path_ids[0]].raw.len == 0) return false;
    const items = switch (resolve(
        value,
        plan.pointers[rule.path_ids[0]],
    ) orelse return false) {
        .array => |array| array.items,
        else => return false,
    };
    if (items.len > plan.max_records) return false;
    var total_bytes = rule.sha256_prefix.?.len;
    if (total_bytes > rule.max_count.?) return false;
    hasher.update(rule.sha256_prefix.?);
    for (items) |item| {
        const key: FormattedReferenceKey = .{
            .parent = value,
            .item = item,
            .value = item,
            .parts = rule.format_parts,
        };
        if (!hashFormattedParts(
            plan,
            rule,
            key,
            &total_bytes,
            hasher,
        )) return false;
    }
    return true;
}

fn hashFramedFields(
    plan: *const Plan,
    rule: *const CompiledRule,
    value: std.json.Value,
    hasher: *std.crypto.hash.sha2.Sha256,
) bool {
    var total_bytes = rule.sha256_prefix.?.len;
    if (total_bytes > rule.max_count.?) return false;
    hasher.update(rule.sha256_prefix.?);
    return hashFormattedParts(
        plan,
        rule,
        .{
            .parent = value,
            .item = value,
            .value = value,
            .parts = rule.format_parts,
        },
        &total_bytes,
        hasher,
    );
}

fn hashFormattedParts(
    plan: *const Plan,
    rule: *const CompiledRule,
    key: FormattedReferenceKey,
    total_bytes: *usize,
    hasher: *std.crypto.hash.sha2.Sha256,
) bool {
    for (rule.format_parts) |part| {
        const fragment = formattedReferenceFragment(
            plan,
            key,
            part,
        ) orelse return false;
        total_bytes.* = std.math.add(
            usize,
            total_bytes.*,
            fragment.len,
        ) catch return false;
        if (total_bytes.* > rule.max_count.?) return false;
        hasher.update(fragment);
    }
    return true;
}

fn sha256FinalMatches(
    hasher: *std.crypto.hash.sha2.Sha256,
    expected: []const u8,
    allow_bare: bool,
) bool {
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    var computed: [71]u8 = undefined;
    @memcpy(computed[0..7], "sha256:");
    @memcpy(computed[7..], &hex);
    return std.mem.eql(u8, expected, &computed) or
        (allow_bare and std.mem.eql(u8, expected, computed[7..]));
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

fn boundedNumber(value: std.json.Value, rule: *const CompiledRule) bool {
    if (rule.min_number) |minimum| {
        const order = exactNumberOrder(
            value,
            numericScalarValue(minimum),
        ) orelse return false;
        if (order == .lt) return false;
    }
    if (rule.max_number) |maximum| {
        const order = exactNumberOrder(
            value,
            numericScalarValue(maximum),
        ) orelse return false;
        if (order == .gt) return false;
    }
    return true;
}

fn declaredFieldValuesHold(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    root: std.json.Value,
    rule: *const CompiledRule,
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

fn boundedCount(value: std.json.Value, kind: JsonKind, rule: *const CompiledRule) bool {
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

fn withinCount(count: usize, rule: *const CompiledRule) bool {
    if (rule.min_count) |minimum| if (count < minimum) return false;
    if (rule.max_count) |maximum| if (count > maximum) return false;
    return true;
}

fn enumContains(values: []const EnumScalar, value: std.json.Value) bool {
    for (values) |candidate| if (enumEqual(candidate, value)) return true;
    return false;
}

fn isNumericScalar(value: EnumScalar) bool {
    return switch (value) {
        .integer, .float, .number => true,
        else => false,
    };
}

fn numericScalarValue(value: EnumScalar) std.json.Value {
    return switch (value) {
        .integer => |number| .{ .integer = number },
        .float => |number| .{ .float = number },
        .number => |number| .{ .number_string = number },
        else => unreachable,
    };
}

fn enumEqual(candidate: EnumScalar, value: std.json.Value) bool {
    return switch (candidate) {
        .string => |text| value == .string and std.mem.eql(u8, text, value.string),
        .integer => |number| exactNumbersEqual(
            .{ .integer = number },
            value,
        ),
        .float => |number| exactNumbersEqual(
            .{ .float = number },
            value,
        ),
        .number => |number| exactNumbersEqual(
            .{ .number_string = number },
            value,
        ),
        .boolean => |flag| value == .bool and flag == value.bool,
        .null => value == .null,
    };
}

fn enumScalarsEqual(left: EnumScalar, right: EnumScalar) bool {
    return switch (left) {
        .string => |text| right == .string and
            std.mem.eql(u8, text, right.string),
        .integer => |number| switch (right) {
            .integer => |other| number == other,
            .float => |other| definition_core.exact_number.valuesEqual(
                .{ .integer = number },
                .{ .float = other },
            ),
            .number => |other| definition_core.exact_number.valuesEqual(
                .{ .integer = number },
                .{ .number_string = other },
            ),
            else => false,
        },
        .float => |number| switch (right) {
            .integer => |other| definition_core.exact_number.valuesEqual(
                .{ .float = number },
                .{ .integer = other },
            ),
            .float => |other| number == other,
            .number => |other| definition_core.exact_number.valuesEqual(
                .{ .float = number },
                .{ .number_string = other },
            ),
            else => false,
        },
        .number => |number| switch (right) {
            .number => |other| definition_core.exact_number.valuesEqual(
                .{ .number_string = number },
                .{ .number_string = other },
            ),
            .integer => |other| definition_core.exact_number.valuesEqual(
                .{ .number_string = number },
                .{ .integer = other },
            ),
            .float => |other| definition_core.exact_number.valuesEqual(
                .{ .number_string = number },
                .{ .float = other },
            ),
            else => false,
        },
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

fn digestHolds(value: std.json.Value, allow_bare: bool) bool {
    const text = switch (value) {
        .string => |text| text,
        else => return false,
    };
    if (definition_core.canonical_json.isFingerprint(text)) return true;
    if (!allow_bare or text.len != 64) return false;
    for (text) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn safeIdentifier(value: std.json.Value, rule: *const CompiledRule) bool {
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

fn safeRelativePath(value: std.json.Value, rule: *const CompiledRule) bool {
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
    rule: *const CompiledRule,
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
    rule: *const CompiledRule,
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
    rule: *const CompiledRule,
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
    if (!try markDirectCorrespondence(
        plan,
        root,
        rule,
        &predecessors,
        &successors,
        &reference_count,
        max_reference_count,
    )) return false;
    if (!try markMappedCorrespondence(
        plan,
        root,
        rule,
        &predecessors,
        &successors,
        &reference_count,
        max_reference_count,
    )) return false;
    return correspondenceComplete(&predecessors) and
        correspondenceComplete(&successors);
}

fn markDirectCorrespondence(
    plan: *const Plan,
    root: std.json.Value,
    rule: *const CompiledRule,
    predecessors: *std.AutoHashMapUnmanaged([32]u8, CorrespondenceEntry),
    successors: *std.AutoHashMapUnmanaged([32]u8, CorrespondenceEntry),
    reference_count: *usize,
    max_reference_count: usize,
) !bool {
    const preserved = try correspondenceReferences(
        plan,
        root,
        rule.path_ids[2],
    ) orelse return false;
    if (!try markPreservedCorrespondence(
        preserved,
        predecessors,
        successors,
        reference_count,
        max_reference_count,
    )) return false;
    const retired = try correspondenceReferences(
        plan,
        root,
        rule.path_ids[3],
    ) orelse return false;
    if (!try markCorrespondenceReferences(
        retired,
        predecessors,
        reference_count,
        max_reference_count,
    )) return false;
    const introduced = try correspondenceReferences(
        plan,
        root,
        rule.path_ids[4],
    ) orelse return false;
    if (!try markCorrespondenceReferences(
        introduced,
        successors,
        reference_count,
        max_reference_count,
    )) return false;
    return true;
}

fn markMappedCorrespondence(
    plan: *const Plan,
    root: std.json.Value,
    rule: *const CompiledRule,
    predecessors: *std.AutoHashMapUnmanaged([32]u8, CorrespondenceEntry),
    successors: *std.AutoHashMapUnmanaged([32]u8, CorrespondenceEntry),
    reference_count: *usize,
    max_reference_count: usize,
) !bool {
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
                predecessors,
                reference_count,
                max_reference_count,
            ) or !try markCorrespondenceReferences(
            successor_refs,
            successors,
            reference_count,
            max_reference_count,
        )) {
            return false;
        }
    }
    return true;
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
    rule: *const CompiledRule,
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
        if (!try markSingleReferenceSource(
            allocator,
            plan,
            rule,
            source_value,
            &index,
            &source_count,
            &reference_count,
        )) return false;
    } else if (!try markDeclaredReferenceSources(
        allocator,
        plan,
        rule,
        source_root,
        &index,
        &source_count,
        &reference_count,
    )) {
        return false;
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

fn markSingleReferenceSource(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: *const CompiledRule,
    source_value: std.json.Value,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    source_count: *usize,
    reference_count: *usize,
) !bool {
    const source_items = switch (source_value) {
        .array => |array| array.items,
        else => return false,
    };
    source_count.* = source_items.len;
    if (source_count.* > plan.max_records) return false;
    return markReferencesFromItems(
        allocator,
        plan,
        rule,
        source_items,
        rule.other_pointer_id.?,
        &.{},
        &.{},
        index,
        reference_count,
    );
}

fn markDeclaredReferenceSources(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: *const CompiledRule,
    source_root: std.json.Value,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    source_count: *usize,
    reference_count: *usize,
) !bool {
    for (rule.reference_sources) |source| {
        const items_value = resolve(
            source_root,
            plan.pointers[source.pointer_id],
        ) orelse {
            if (source.optional) continue;
            return false;
        };
        const singleton_items = [1]std.json.Value{items_value};
        const items = switch (items_value) {
            .array => |array| array.items,
            else => if (source.singleton)
                singleton_items[0..]
            else
                return false,
        };
        if (!try markDeclaredReferenceSource(
            allocator,
            plan,
            rule,
            source,
            items,
            index,
            source_count,
            reference_count,
        )) return false;
    }
    return true;
}

fn markDeclaredReferenceSource(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: *const CompiledRule,
    source: CompiledReferenceSource,
    items: []const std.json.Value,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    source_count: *usize,
    reference_count: *usize,
) !bool {
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
            if (!try addReferenceSourceItems(
                allocator,
                plan,
                rule,
                source,
                nested_items,
                index,
                source_count,
                reference_count,
            )) return false;
        }
        return true;
    }
    return addReferenceSourceItems(
        allocator,
        plan,
        rule,
        source,
        items,
        index,
        source_count,
        reference_count,
    );
}

fn addReferenceSourceItems(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: *const CompiledRule,
    source: CompiledReferenceSource,
    items: []const std.json.Value,
    index: *std.AutoHashMapUnmanaged([32]u8, ReferenceTarget),
    source_count: *usize,
    reference_count: *usize,
) !bool {
    source_count.* = std.math.add(
        usize,
        source_count.*,
        items.len,
    ) catch return false;
    if (source_count.* > plan.max_records) return false;
    return markReferencesFromItems(
        allocator,
        plan,
        rule,
        items,
        source.reference_pointer_id,
        source.rules,
        source.format_parts,
        index,
        reference_count,
    );
}

fn markReferencesFromItems(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    rule: *const CompiledRule,
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
    rule: *const CompiledRule,
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
    rule: *const CompiledRule,
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
    rule: *const CompiledRule,
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
            var buffer: [128]u8 = undefined;
            const number = definition_core.exact_number.fromValue(
                value,
                &buffer,
            ) orelse return null;
            hasher.update("number:");
            hasher.update(if (number.negative) "-" else "+");
            var scale_buffer: [32]u8 = undefined;
            const scale = std.fmt.bufPrint(
                &scale_buffer,
                "{d}:",
                .{number.scale},
            ) catch return null;
            hasher.update(scale);
            if (number.significant_len == 0) {
                hasher.update("0");
            } else {
                var index: usize = 0;
                while (index < number.significant_len) : (index += 1) {
                    const digit = [1]u8{number.digit(index)};
                    hasher.update(&digit);
                }
            }
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

const ValuePair = struct {
    left: std.json.Value,
    right: std.json.Value,
};

pub fn valuesEqual(left: std.json.Value, right: std.json.Value) bool {
    var stack = std.heap.stackFallback(4096, std.heap.page_allocator);
    const allocator = stack.get();
    var pending: std.ArrayList(ValuePair) = .empty;
    defer pending.deinit(allocator);
    pending.append(allocator, .{
        .left = left,
        .right = right,
    }) catch return false;
    var visited: usize = 0;
    while (pending.pop()) |pair| {
        visited = std.math.add(usize, visited, 1) catch return false;
        if (visited > max_value_equality_pairs) return false;
        if (!valuePairEqualOrExpanded(
            allocator,
            pair,
            &pending,
        )) return false;
    }
    return true;
}

fn valuePairEqualOrExpanded(
    allocator: std.mem.Allocator,
    pair: ValuePair,
    pending: *std.ArrayList(ValuePair),
) bool {
    if (isJsonNumber(pair.left) or isJsonNumber(pair.right)) {
        return exactNumbersEqual(pair.left, pair.right);
    }
    if (std.meta.activeTag(pair.left) != std.meta.activeTag(pair.right)) {
        return false;
    }
    return switch (pair.left) {
        .null => true,
        .bool => |value| value == pair.right.bool,
        .integer => |value| value == pair.right.integer,
        .float => |value| value == pair.right.float,
        .number_string => |value| std.mem.eql(
            u8,
            value,
            pair.right.number_string,
        ),
        .string => |value| std.mem.eql(u8, value, pair.right.string),
        .array => |array| appendArrayPairs(
            allocator,
            array.items,
            pair.right.array.items,
            pending,
        ),
        .object => |object| appendObjectPairs(
            allocator,
            object,
            pair.right.object,
            pending,
        ),
    };
}

fn appendArrayPairs(
    allocator: std.mem.Allocator,
    left: []const std.json.Value,
    right: []const std.json.Value,
    pending: *std.ArrayList(ValuePair),
) bool {
    if (left.len != right.len) return false;
    const pending_count = std.math.add(
        usize,
        pending.items.len,
        left.len,
    ) catch return false;
    if (pending_count > max_value_equality_pairs) {
        return false;
    }
    for (left, right) |left_value, right_value| {
        pending.append(allocator, .{
            .left = left_value,
            .right = right_value,
        }) catch return false;
    }
    return true;
}

fn appendObjectPairs(
    allocator: std.mem.Allocator,
    left: std.json.ObjectMap,
    right: std.json.ObjectMap,
    pending: *std.ArrayList(ValuePair),
) bool {
    if (left.count() != right.count()) return false;
    const pending_count = std.math.add(
        usize,
        pending.items.len,
        left.count(),
    ) catch return false;
    if (pending_count > max_value_equality_pairs) {
        return false;
    }
    var iterator = left.iterator();
    while (iterator.next()) |entry| {
        const other = right.get(entry.key_ptr.*) orelse return false;
        pending.append(allocator, .{
            .left = entry.value_ptr.*,
            .right = other,
        }) catch return false;
    }
    return true;
}

fn valueOrder(left: std.json.Value, right: std.json.Value) std.math.Order {
    if (left == .string and right == .string) return std.mem.order(u8, left.string, right.string);
    if (left == .bool and right == .bool) {
        if (left.bool == right.bool) return .eq;
        return if (!left.bool and right.bool) .lt else .gt;
    }
    return exactNumberOrder(left, right) orelse
        if (isJsonNumber(left)) .lt else .gt;
}

fn isJsonNumber(value: std.json.Value) bool {
    return value == .integer or value == .float or value == .number_string;
}

fn exactNumbersEqual(left: std.json.Value, right: std.json.Value) bool {
    return definition_core.exact_number.valuesEqual(left, right);
}

fn exactNumberOrder(
    left: std.json.Value,
    right: std.json.Value,
) ?std.math.Order {
    return definition_core.exact_number.orderValues(left, right);
}

test "relational numbers preserve exact JSON values" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[9007199254740992.0,9007199254740993.0,1,1.0,1e0,-0.0,0]",
        .{ .parse_numbers = false },
    );
    defer parsed.deinit();
    const values = parsed.value.array.items;
    try std.testing.expect(!valuesEqual(values[0], values[1]));
    try std.testing.expect(
        !std.mem.eql(
            u8,
            &scalarKeyDigest(values[0]).?,
            &scalarKeyDigest(values[1]).?,
        ),
    );
    try std.testing.expectEqual(
        std.math.Order.lt,
        valueOrder(values[0], values[1]),
    );
    try std.testing.expect(valuesEqual(values[2], values[3]));
    try std.testing.expect(valuesEqual(values[3], values[4]));
    try std.testing.expect(valuesEqual(values[5], values[6]));
    try std.testing.expectEqual(
        scalarKeyDigest(values[2]).?,
        scalarKeyDigest(values[4]).?,
    );
}

test "parsed-number normalization preserves exact integral decimals" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[9007199254740992.0,9007199254740993.0,1.0]",
        .{ .parse_numbers = false },
    );
    defer parsed.deinit();
    try normalizeParsedNumbers(
        std.testing.allocator,
        &parsed.value,
    );
    const values = parsed.value.array.items;
    try std.testing.expectEqual(
        @as(i64, 9_007_199_254_740_993),
        values[1].integer,
    );
    try std.testing.expect(valuesEqual(values[2], .{ .integer = 1 }));
}

test "compiled uniqueness distinguishes adjacent large JSON numbers" {
    const definition_bytes =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/exact-number-set","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["unique"]},"inputs":{"record":{"codec":"json","max_bytes":128}},"canonicalization":{},"shape":{"documents":{"record":{"unique":true}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":128,"max_store_bytes":128,"max_records":8,"max_output_bytes":128,"max_diagnostics":4,"max_reducer_states":1}}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = definition_bytes,
    });
    var plan = try ValidationTestPlan.init(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        8 * 1024 * 1024,
    );
    defer plan.deinit();
    try expectTestValidation(
        &plan.definition_plan,
        &plan.cached,
        "record",
        "[9007199254740992.0,9007199254740993.0]",
        true,
    );
    try expectTestValidation(
        &plan.definition_plan,
        &plan.cached,
        "record",
        "[1,1.0]",
        false,
    );
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

fn compileForbiddenObjectKeysRule(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    allow_input: bool,
    rule: *CompiledRule,
) !void {
    if (allow_input) {
        try definition_core.json.requireExactKeys(object, &.{
            "op",
            "input",
            "path",
            "keys",
            "case_insensitive",
            "max_depth",
            "max_nodes",
        });
    } else {
        try definition_core.json.requireExactKeys(object, &.{
            "op",
            "path",
            "keys",
            "case_insensitive",
            "max_depth",
            "max_nodes",
        });
    }
    try definition_core.json.requireFields(
        object,
        &.{ "op", "path", "keys", "max_depth", "max_nodes" },
    );
    rule.keys = try parseStringSet(
        allocator,
        try definition_core.json.field(object, "keys"),
    );
    if (rule.keys.len == 0 or rule.keys.len > 64) {
        return error.InvalidForbiddenObjectKeyCount;
    }
    for (rule.keys, 0..) |key, index| {
        if (key.len == 0 or key.len > 256) {
            return error.InvalidForbiddenObjectKey;
        }
        for (rule.keys[0..index]) |prior| {
            if (std.ascii.eqlIgnoreCase(prior, key)) {
                return error.DuplicateForbiddenObjectKey;
            }
        }
    }
    rule.case_insensitive =
        try optionalBoolean(object, "case_insensitive") orelse false;
    rule.min_count = try optionalUnsigned(object, "max_depth") orelse
        return error.MissingForbiddenObjectKeyBound;
    rule.max_count = try optionalUnsigned(object, "max_nodes") orelse
        return error.MissingForbiddenObjectKeyBound;
    if (rule.min_count.? == 0 or rule.min_count.? > 128 or
        rule.max_count.? == 0 or rule.max_count.? > 1_000_000)
    {
        return error.InvalidForbiddenObjectKeyBound;
    }
}

fn compileRegexPatterns(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) ![]CompiledRegexPattern {
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or values.items.len > max_regex_patterns) {
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
        if (total_atoms > max_regex_total_atoms) {
            return error.RegexStateBoundExceeded;
        }
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
        const bytes = try compileRegexAtomBytes(expression, &index);
        if (index < expression.len and expression[index] == '{') {
            const repetition = try readRegexRepetition(expression, &index);
            try appendRepeatedRegexAtoms(
                allocator,
                &atoms,
                bytes,
                repetition,
            );
        } else {
            try appendSingleRegexAtom(
                allocator,
                &atoms,
                bytes,
                expression,
                &index,
            );
        }
    }
    if (atoms.items.len == 0) return error.RegexPatternEmpty;
    return .{ .atoms = try atoms.toOwnedSlice(allocator) };
}

fn compileRegexAtomBytes(
    expression: []const u8,
    index: *usize,
) ![4]u64 {
    var bytes: [4]u64 = @splat(0);
    switch (expression[index.*]) {
        '\\' => {
            index.* += 1;
            if (index.* >= expression.len) return error.RegexEscapeInvalid;
            regexByteSet(&bytes, expression[index.*]);
            index.* += 1;
        },
        '[' => bytes = try compileRegexClass(expression, index),
        '.' => {
            bytes = @splat(std.math.maxInt(u64));
            regexByteClear(&bytes, '\n');
            regexByteClear(&bytes, '\r');
            index.* += 1;
        },
        '*', '+', '?', '{', '}', '(', ')', '|', '^', '$', ']' => {
            return error.RegexConstructUnsupported;
        },
        else => |byte| {
            regexByteSet(&bytes, byte);
            index.* += 1;
        },
    }
    return bytes;
}

fn appendRepeatedRegexAtoms(
    allocator: std.mem.Allocator,
    atoms: *std.ArrayList(CompiledRegexAtom),
    bytes: [4]u64,
    repetition: RegexRepetition,
) !void {
    for (0..repetition.maximum) |repetition_index| {
        if (atoms.items.len >= max_regex_atoms_per_pattern) {
            return error.RegexStateBoundExceeded;
        }
        try atoms.append(allocator, .{
            .bytes = bytes,
            .quantifier = if (repetition_index < repetition.minimum)
                .one
            else
                .zero_or_one,
        });
    }
}

fn appendSingleRegexAtom(
    allocator: std.mem.Allocator,
    atoms: *std.ArrayList(CompiledRegexAtom),
    bytes: [4]u64,
    expression: []const u8,
    index: *usize,
) !void {
    var quantifier: RegexQuantifier = .one;
    if (index.* < expression.len) {
        quantifier = switch (expression[index.*]) {
            '?' => .zero_or_one,
            '*' => .zero_or_more,
            '+' => .one_or_more,
            else => .one,
        };
        if (quantifier != .one) index.* += 1;
    }
    if (atoms.items.len >= max_regex_atoms_per_pattern) {
        return error.RegexStateBoundExceeded;
    }
    try atoms.append(allocator, .{
        .bytes = bytes,
        .quantifier = quantifier,
    });
}

fn readRegexRepetition(
    expression: []const u8,
    index: *usize,
) !RegexRepetition {
    std.debug.assert(index.* < expression.len and expression[index.*] == '{');
    index.* += 1;
    const minimum = try readRegexRepetitionCount(expression, index);
    var maximum = minimum;
    if (index.* < expression.len and expression[index.*] == ',') {
        index.* += 1;
        maximum = try readRegexRepetitionCount(expression, index);
    }
    if (index.* >= expression.len or expression[index.*] != '}') {
        return error.RegexRepetitionUnclosed;
    }
    index.* += 1;
    if (minimum > maximum) return error.RegexRepetitionInvalid;
    if (maximum > max_regex_atoms_per_pattern) {
        return error.RegexStateBoundExceeded;
    }
    return .{ .minimum = minimum, .maximum = maximum };
}

fn readRegexRepetitionCount(
    expression: []const u8,
    index: *usize,
) !usize {
    const start = index.*;
    var count: usize = 0;
    while (index.* < expression.len and
        std.ascii.isDigit(expression[index.*]))
    {
        count = std.math.mul(usize, count, 10) catch
            return error.RegexRepetitionInvalid;
        count = std.math.add(
            usize,
            count,
            expression[index.*] - '0',
        ) catch return error.RegexRepetitionInvalid;
        index.* += 1;
    }
    if (index.* == start) return error.RegexRepetitionInvalid;
    return count;
}

test "compiled regex expands bounded repetitions once" {
    var exact = try compileRegexPattern(
        std.testing.allocator,
        "^[A-Fa-f0-9]{40}$",
    );
    defer exact.deinit(std.testing.allocator);
    const forty: [40]u8 = @splat('a');
    const thirty_nine: [39]u8 = @splat('a');
    const forty_one: [41]u8 = @splat('a');
    try std.testing.expect(compiledRegexMatches(&forty, exact));
    try std.testing.expect(!compiledRegexMatches(&thirty_nine, exact));
    try std.testing.expect(!compiledRegexMatches(&forty_one, exact));

    var range = try compileRegexPattern(std.testing.allocator, "^x{2,4}$");
    defer range.deinit(std.testing.allocator);
    try std.testing.expect(!compiledRegexMatches("x", range));
    try std.testing.expect(compiledRegexMatches("xx", range));
    try std.testing.expect(compiledRegexMatches("xxx", range));
    try std.testing.expect(compiledRegexMatches("xxxx", range));
    try std.testing.expect(!compiledRegexMatches("xxxxx", range));

    try std.testing.expectError(
        error.RegexRepetitionInvalid,
        compileRegexPattern(std.testing.allocator, "^x{4,2}$"),
    );
    try std.testing.expectError(
        error.RegexStateBoundExceeded,
        compileRegexPattern(std.testing.allocator, "^x{256}$"),
    );
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
    std.sort.heap([]u8, out, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    if (out.len > 1) {
        for (out[1..], 1..) |value, index| {
            if (std.mem.eql(u8, out[index - 1], value)) {
                return error.DuplicateRuleValue;
            }
        }
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
        .number_string => |number| .{
            .number = try allocator.dupe(u8, number),
        },
        .bool => |flag| .{ .boolean = flag },
        .null => .null,
        else => error.InvalidEnumValue,
    };
}

test "numeric enums preserve exact values beyond binary float precision" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[9223372036854775808,9223372036854775809]",
        .{ .parse_numbers = false },
    );
    defer parsed.deinit();
    var scalar = try parseEnumScalar(
        std.testing.allocator,
        parsed.value.array.items[0],
    );
    defer scalar.deinit(std.testing.allocator);
    try std.testing.expect(enumEqual(scalar, parsed.value.array.items[0]));
    try std.testing.expect(!enumEqual(scalar, parsed.value.array.items[1]));
}

test "bounded numbers preserve exact definition thresholds through cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/exact-bounds","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["bounded-number","exact-object"]},"parameters":{},"inputs":{"record":{"codec":"json","required":true,"max_bytes":4096}},"canonicalization":{},"shape":{"documents":{"record":{"object":"exact","fields":{"value":{"number":{"min":9007199254740993,"max":9007199254740995}}}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
    ;
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "definition.json",
        .data = source,
    });
    var test_plan = try ValidationTestPlan.init(
        std.testing.allocator,
        &tmp.dir,
        "definition.json",
        1024 * 1024,
    );
    defer test_plan.deinit();
    try expectTestValidation(
        &test_plan.definition_plan,
        &test_plan.cached,
        "record",
        "{\"value\":9007199254740993}",
        true,
    );
    try expectTestValidation(
        &test_plan.definition_plan,
        &test_plan.cached,
        "record",
        "{\"value\":9007199254740992}",
        false,
    );
}

fn optionalUnsigned(object: std.json.ObjectMap, name: []const u8) !?usize {
    const raw = object.get(name) orelse return null;
    return try definition_core.json.unsigned(raw);
}

fn optionalNumber(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
) !?EnumScalar {
    const raw = object.get(name) orelse return null;
    var scalar = try parseEnumScalar(allocator, raw);
    errdefer scalar.deinit(allocator);
    if (!isNumericScalar(scalar)) return error.ExpectedNumber;
    return scalar;
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
        .not_member_of,
        .exactly_one,
        .at_least_one,
        .all_rules,
        .any_rules,
        .no_rules,
        .object_values,
        .forbidden_object_keys,
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

fn isPrimitiveItemOperator(operator: definition.Operator) bool {
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
        .unique,
        .sorted,
        .forbidden_object_keys,
        => true,
        else => false,
    };
}

fn isPrimitiveRootOperator(operator: definition.Operator) bool {
    return switch (operator) {
        .exact_object,
        .field_absent,
        .forbidden_object_keys,
        .optional_field,
        .scalar_type,
        .bounded_array,
        .bounded_object,
        .bounded_string,
        .regex,
        .digest,
        .timestamp,
        .sha256,
        .safe_identifier,
        .safe_relative_path,
        .sorted,
        .bounded_number,
        .enum_value,
        => true,
        else => false,
    };
}

fn isRelationalRootOperator(operator: definition.Operator) bool {
    return switch (operator) {
        .set_equality,
        .subset,
        .superset,
        .disjoint,
        .path_scope_subset,
        .path_scope_disjoint,
        .member_of,
        .not_member_of,
        .field_equal,
        .field_not_equal,
        .declared_field_values,
        .cross_input_equal,
        .implies,
        .total_partition,
        .total_mapping,
        .path_format,
        .exactly_one,
        .at_least_one,
        .keyed_join,
        .predecessor_successor,
        => true,
        else => false,
    };
}

fn requireRootPathOnly(object: std.json.ObjectMap) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "input", "path" },
    );
    try definition_core.json.requireFields(object, &.{ "op", "path" });
}

fn compileDigestRule(
    object: std.json.ObjectMap,
    root: bool,
    rule: *CompiledRule,
) !void {
    if (root) {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "input", "path", "allow_bare" },
        );
    } else {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "path", "allow_bare" },
        );
    }
    try definition_core.json.requireFields(object, &.{ "op", "path" });
    rule.allow_bare_digest =
        try optionalBoolean(object, "allow_bare") orelse false;
}

fn compileCountBoundRootRule(
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
    rule.min_count = try optionalUnsigned(object, "min");
    rule.max_count = try optionalUnsigned(object, "max");
    try validateCountBounds(rule);
}

fn compileStringBoundRootRule(
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "input", "path", "min", "max", "trimmed_min" },
    );
    rule.min_count = try optionalUnsigned(object, "min");
    rule.max_count = try optionalUnsigned(object, "max");
    rule.trimmed_min_count = try optionalUnsigned(object, "trimmed_min");
    if (rule.min_count == null and
        rule.max_count == null and
        rule.trimmed_min_count == null)
    {
        return error.MissingRuleBound;
    }
    if (rule.min_count != null or rule.max_count != null) {
        try validateCountBounds(rule);
    }
    if (rule.trimmed_min_count != null and
        rule.max_count != null and
        rule.trimmed_min_count.? > rule.max_count.?)
    {
        return error.InvalidRuleBounds;
    }
}

fn compileRegexRootRule(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
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
        allocator,
        try definition_core.json.field(object, "patterns"),
    );
}

fn compileIdentifierRootRule(
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "input", "path", "min", "max", "style" },
    );
    rule.min_count = try optionalUnsigned(object, "min");
    rule.max_count = try optionalUnsigned(object, "max");
    if (rule.min_count != null and
        rule.max_count != null and
        rule.min_count.? > rule.max_count.?)
    {
        return error.InvalidRuleBounds;
    }
    if (object.get("style")) |raw| {
        rule.identifier_style = try IdentifierStyle.parse(
            try definition_core.json.string(raw),
        );
    }
}

fn compileNumberBoundRootRule(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
    rule.min_number = try optionalNumber(allocator, object, "min");
    rule.max_number = try optionalNumber(allocator, object, "max");
    if (rule.min_number == null and rule.max_number == null) {
        return error.MissingRuleBound;
    }
    if (rule.min_number != null and
        rule.max_number != null and
        exactNumberOrder(
            numericScalarValue(rule.min_number.?),
            numericScalarValue(rule.max_number.?),
        ) == .gt)
    {
        return error.InvalidRuleBounds;
    }
}

fn requireDeclaredValuesKeys(object: std.json.ObjectMap) !void {
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
}

fn requireMappingKeys(object: std.json.ObjectMap) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "input", "source", "target", "mapping", "from", "to" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "op", "source", "target", "mapping", "from", "to" },
    );
}

fn requireKeyedJoinKeys(object: std.json.ObjectMap) !void {
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
        &.{ "op", "collection", "key", "selector", "value", "equals" },
    );
}

fn requireCorrespondenceKeys(object: std.json.ObjectMap) !void {
    const keys = [_][]const u8{
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
    };
    try definition_core.json.requireExactKeys(object, &keys);
    try definition_core.json.requireFields(object, keys[2..]);
}

fn compileScalarItemRule(
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "path", "type" },
    );
    rule.scalar_kind = try JsonKind.parse(
        try definition_core.json.requiredString(object, "type"),
    );
}

fn compileCountBoundItemRule(
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "path", "min", "max" },
    );
    rule.min_count = try optionalUnsigned(object, "min");
    rule.max_count = try optionalUnsigned(object, "max");
    try validateCountBounds(rule);
}

fn compileStringBoundItemRule(
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "path", "min", "max", "trimmed_min" },
    );
    rule.min_count = try optionalUnsigned(object, "min");
    rule.max_count = try optionalUnsigned(object, "max");
    rule.trimmed_min_count = try optionalUnsigned(object, "trimmed_min");
    if (rule.min_count == null and
        rule.max_count == null and
        rule.trimmed_min_count == null)
    {
        return error.MissingRuleBound;
    }
    if (rule.min_count != null or rule.max_count != null) {
        try validateCountBounds(rule);
    }
    if (rule.trimmed_min_count != null and
        rule.max_count != null and
        rule.trimmed_min_count.? > rule.max_count.?)
    {
        return error.InvalidRuleBounds;
    }
}

fn validateCountBounds(rule: *const CompiledRule) !void {
    if (rule.min_count == null and rule.max_count == null) {
        return error.MissingRuleBound;
    }
    if (rule.min_count != null and
        rule.max_count != null and
        rule.min_count.? > rule.max_count.?)
    {
        return error.InvalidRuleBounds;
    }
}

fn compileRegexItemRule(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
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
        allocator,
        try definition_core.json.field(object, "patterns"),
    );
}

fn compileIdentifierItemRule(
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "path", "min", "max", "style" },
    );
    rule.min_count = try optionalUnsigned(object, "min");
    rule.max_count = try optionalUnsigned(object, "max");
    if (rule.min_count != null and
        rule.max_count != null and
        rule.min_count.? > rule.max_count.?)
    {
        return error.InvalidRuleBounds;
    }
    if (object.get("style")) |raw| {
        rule.identifier_style = try IdentifierStyle.parse(
            try definition_core.json.string(raw),
        );
    }
}

fn compileNumberBoundItemRule(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "path", "min", "max" },
    );
    rule.min_number = try optionalNumber(allocator, object, "min");
    rule.max_number = try optionalNumber(allocator, object, "max");
    if (rule.min_number == null and rule.max_number == null) {
        return error.MissingRuleBound;
    }
    if (rule.min_number != null and
        rule.max_number != null and
        exactNumberOrder(
            numericScalarValue(rule.min_number.?),
            numericScalarValue(rule.max_number.?),
        ) == .gt)
    {
        return error.InvalidRuleBounds;
    }
}

fn compileEnumItemRule(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "path", "values" },
    );
    rule.values = try parseEnumValues(
        allocator,
        try definition_core.json.field(object, "values"),
    );
}

fn requireReferenceItemKeys(object: std.json.ObjectMap) !void {
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
}

fn requireReferenceRootKeys(object: std.json.ObjectMap) !void {
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
}

fn hasSingleReferenceTargetFields(object: std.json.ObjectMap) bool {
    return object.get("target") != null or
        object.get("target_items") != null or
        object.get("target_rules") != null or
        object.get("coverage_rules") != null or
        object.get("key") != null;
}

fn compileReferenceRootPolicies(
    object: std.json.ObjectMap,
    rule: *CompiledRule,
) !void {
    if (object.get("coverage")) |raw_coverage| {
        const coverage = try definition_core.json.string(raw_coverage);
        if (!std.mem.eql(u8, coverage, "all-targets")) {
            return error.UnsupportedReferenceCoverage;
        }
        rule.total_coverage = true;
    }
    if (object.get("self_reference")) |raw_policy| {
        const policy = try definition_core.json.string(raw_policy);
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
}

fn compileReferencePolicies(
    object: std.json.ObjectMap,
    source_pointer_id: u16,
    rule: *CompiledRule,
) !void {
    if (object.get("coverage")) |raw_coverage| {
        const coverage = try definition_core.json.string(raw_coverage);
        if (!std.mem.eql(u8, coverage, "all-targets")) {
            return error.UnsupportedReferenceCoverage;
        }
        rule.total_coverage = true;
    }
    if (object.get("self_reference")) |raw_policy| {
        const policy = try definition_core.json.string(raw_policy);
        if (!std.mem.eql(u8, policy, "reject")) {
            return error.UnsupportedSelfReferencePolicy;
        }
        if (rule.path_ids[0] != source_pointer_id) {
            return error.SelfReferenceRequiresOneCollection;
        }
        rule.reject_self_reference = true;
    }
    rule.ignore_null_references =
        try optionalBoolean(object, "ignore_null") orelse false;
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
        .not_member_of,
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
        .forbidden_object_keys,
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

const ValidationTestPlan = struct {
    allocator: std.mem.Allocator,
    closure: definition_core.Closure,
    definition_plan: definition.Plan,
    plan: Plan,
    payload: []u8,
    cached: Plan,

    fn init(
        allocator: std.mem.Allocator,
        directory: anytype,
        path: []const u8,
        cache_limit: usize,
    ) !ValidationTestPlan {
        var closure = try definition_core.closure.loadFromDir(
            allocator,
            directory,
            path,
            .{},
        );
        errdefer closure.deinit(allocator);
        var definition_plan = try definition.compile(
            allocator,
            &closure,
            path,
        );
        errdefer definition_plan.deinit(allocator);
        var plan = try compile(allocator, &definition_plan);
        errdefer plan.deinit(allocator);
        var encoder = definition_core.cache.Encoder.init(
            allocator,
            cache_limit,
        );
        defer encoder.deinit();
        try encodeCache(&plan, &encoder);
        const payload = try encoder.toOwnedSlice();
        errdefer allocator.free(payload);
        var decoder = definition_core.cache.Decoder.init(payload);
        var cached = try decodeCache(allocator, &decoder);
        errdefer cached.deinit(allocator);
        try decoder.finish();
        try validateCachePlan(&cached, &definition_plan);
        return .{
            .allocator = allocator,
            .closure = closure,
            .definition_plan = definition_plan,
            .plan = plan,
            .payload = payload,
            .cached = cached,
        };
    }

    fn deinit(self: *ValidationTestPlan) void {
        self.cached.deinit(self.allocator);
        self.allocator.free(self.payload);
        self.plan.deinit(self.allocator);
        self.definition_plan.deinit(self.allocator);
        self.closure.deinit(self.allocator);
        self.* = undefined;
    }

    fn checkAllocationFailures(self: *const ValidationTestPlan) !void {
        try std.testing.checkAllAllocationFailures(
            self.allocator,
            compileForAllocationFailure,
            .{&self.definition_plan},
        );
        try std.testing.checkAllAllocationFailures(
            self.allocator,
            decodeForAllocationFailure,
            .{self.payload},
        );
    }

    fn expectCacheShape(self: *const ValidationTestPlan) !void {
        try std.testing.expectEqual(
            self.plan.inputs.len,
            self.cached.inputs.len,
        );
        try std.testing.expectEqual(
            self.plan.pointers.len,
            self.cached.pointers.len,
        );
        try std.testing.expectEqual(
            self.plan.rules.len,
            self.cached.rules.len,
        );
    }

    fn checkValidationAllocationFailures(
        self: *const ValidationTestPlan,
        bytes: []const u8,
    ) !void {
        try std.testing.checkAllAllocationFailures(
            self.allocator,
            validateForAllocationFailure,
            .{ &self.definition_plan, &self.plan, bytes },
        );
    }
};

const DefinitionReferenceTestPlan = struct {
    allocator: std.mem.Allocator,
    closure: definition_core.Closure,
    definition_plan: definition.Plan,
    definition_payload: []u8,
    cached_definition: definition.Plan,
    plan: Plan,
    payload: []u8,
    cached: Plan,

    fn init(
        allocator: std.mem.Allocator,
        directory: anytype,
    ) !DefinitionReferenceTestPlan {
        var closure = try definition_core.closure.loadFromDir(
            allocator,
            directory,
            "packet.json",
            .{},
        );
        errdefer closure.deinit(allocator);
        var definition_plan = try definition.compile(
            allocator,
            &closure,
            "packet.json",
        );
        errdefer definition_plan.deinit(allocator);
        var definition_encoder = definition_core.cache.Encoder.init(
            allocator,
            8 * 1024 * 1024,
        );
        defer definition_encoder.deinit();
        try definition.encodeCache(
            &definition_plan,
            &definition_encoder,
        );
        const definition_payload =
            try definition_encoder.toOwnedSlice();
        errdefer allocator.free(definition_payload);
        var definition_decoder =
            definition_core.cache.Decoder.init(definition_payload);
        var cached_definition = try definition.decodeCache(
            allocator,
            &definition_decoder,
        );
        errdefer cached_definition.deinit(allocator);
        try definition_decoder.finish();
        var plan = try compile(allocator, &cached_definition);
        errdefer plan.deinit(allocator);
        var encoder = definition_core.cache.Encoder.init(
            allocator,
            8 * 1024 * 1024,
        );
        defer encoder.deinit();
        try encodeCache(&plan, &encoder);
        const payload = try encoder.toOwnedSlice();
        errdefer allocator.free(payload);
        var decoder = definition_core.cache.Decoder.init(payload);
        var cached = try decodeCache(allocator, &decoder);
        errdefer cached.deinit(allocator);
        try decoder.finish();
        try validateCachePlan(&cached, &cached_definition);
        return .{
            .allocator = allocator,
            .closure = closure,
            .definition_plan = definition_plan,
            .definition_payload = definition_payload,
            .cached_definition = cached_definition,
            .plan = plan,
            .payload = payload,
            .cached = cached,
        };
    }

    fn deinit(self: *DefinitionReferenceTestPlan) void {
        self.cached.deinit(self.allocator);
        self.allocator.free(self.payload);
        self.plan.deinit(self.allocator);
        self.cached_definition.deinit(self.allocator);
        self.allocator.free(self.definition_payload);
        self.definition_plan.deinit(self.allocator);
        self.closure.deinit(self.allocator);
        self.* = undefined;
    }
};

fn expectTestValidation(
    definition_plan: *const definition.Plan,
    plan: *const Plan,
    input_name: []const u8,
    bytes: []const u8,
    expected: bool,
) !void {
    var result = try validate(
        std.testing.allocator,
        definition_plan,
        plan,
        &.{.{ .name = input_name, .bytes = bytes }},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, result.valid);
}

fn expectValidTestEnvelope(
    test_plan: *const ValidationTestPlan,
    bytes: []const u8,
) !void {
    var result = try validate(
        std.testing.allocator,
        &test_plan.definition_plan,
        &test_plan.cached,
        &.{.{ .name = "record", .bytes = bytes }},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.valid);
    try std.testing.expect(!result.authority_granted);
    try std.testing.expect(!result.storage_mutated);
}

fn expectReplacementValidation(
    definition_plan: *const definition.Plan,
    plan: *const Plan,
    base: []const u8,
    before: []const u8,
    after: []const u8,
    expected: bool,
) !void {
    const bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        base,
        before,
        after,
    );
    defer std.testing.allocator.free(bytes);
    try expectTestValidation(
        definition_plan,
        plan,
        "record",
        bytes,
        expected,
    );
}

fn checkShapeValidationVariants(
    test_plan: *const ValidationTestPlan,
    valid_bytes: []const u8,
) !void {
    const definition_plan = &test_plan.definition_plan;
    const plan = &test_plan.cached;
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"extension\":\"preserved\"",
        "\"extension\":\"preserved\",\"forbidden\":true",
        false,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"speed\":90,\"cost\":10",
        "\"speed\":90",
        false,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "{\"increase\":\"speed\"},{\"decrease\":\"cost\"}",
        "{\"increase\":\"speed\"},{\"decrease\":\"speed\"}",
        false,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"speed\":90,\"cost\":10",
        "\"speed\":101,\"cost\":10",
        false,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"meta\":{}",
        "\"meta\":{\"closure\":\"confirmed\"}",
        true,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"meta\":{}",
        "\"meta\":{\"closure\":\"wrong\"}",
        false,
    );
}

fn checkReferenceValidationVariants(
    test_plan: *const ValidationTestPlan,
    valid_bytes: []const u8,
) !void {
    const definition_plan = &test_plan.definition_plan;
    const plan = &test_plan.cached;
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"meta\":{}",
        "\"meta\":{\"entry\":{\"value\":1}}",
        false,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"accepted\":[\"a\"]",
        "\"accepted\":[\"missing\"]",
        false,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"ordering\":[\"a\",\"b\"]",
        "\"ordering\":[\"a\"]",
        false,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"related_ids\":[\"item-2\"]",
        "\"related_ids\":[\"item-1\"]",
        false,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"selected\":[\"nested-1\"]",
        "\"selected\":[\"nested-3\"]",
        false,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"checks\":[\"item-1\",\"g:one\"]",
        "\"checks\":[\"item-1\",\"g:missing\"]",
        false,
    );
}

fn checkProtocolValidationVariants(
    test_plan: *const ValidationTestPlan,
    valid_bytes: []const u8,
) !void {
    const definition_plan = &test_plan.definition_plan;
    const plan = &test_plan.cached;
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"guards\":[{\"mode\":\"active\",\"ids\":[],\"kinds\":[\"shared\"]}," ++
            "{\"mode\":\"inactive\",\"ids\":[],\"kinds\":[\"missing\"]}]",
        "\"guards\":[{\"mode\":\"active\",\"ids\":[\"item-1\"],\"kinds\":[]}," ++
            "{\"mode\":\"inactive\",\"ids\":[],\"kinds\":[\"shared\"]}]",
        false,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"id\":\"item-2\",\"kind\":\"shared\",\"state\":\"ready\"",
        "\"id\":\"item-2\",\"kind\":\"shared\",\"state\":\"blocked\"",
        false,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"changes\":[]",
        "\"changes\":[\"changed\"]",
        false,
    );
    try expectReplacementValidation(
        definition_plan,
        plan,
        valid_bytes,
        "\"label\":\"g:one\"",
        "\"label\":\"wrong\"",
        false,
    );
}

fn checkInvalidDiagnosticSet(
    test_plan: *const ValidationTestPlan,
) !void {
    var invalid = try validate(
        std.testing.allocator,
        &test_plan.definition_plan,
        &test_plan.plan,
        &.{.{
            .name = "record",
            .bytes = validation_invalid_record_bytes,
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
}

fn testSha256Digest(parts: []const []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| hasher.update(part);
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.allocPrint(
        std.testing.allocator,
        "sha256:{s}",
        .{hex},
    );
}

const test_resource_digest =
    "sha256:1111111111111111111111111111111111111111111111111111111111111111";

const ShaTestVectors = struct {
    document_digest: []u8,
    framed_digest: []u8,
    field_digest: []u8,
    transport_digest: []u8,
    valid_bytes: []u8,

    fn init() !ShaTestVectors {
        const allocator = std.testing.allocator;
        const document_digest =
            try definition_core.canonical_json.digestBytesAlloc(
                allocator,
                "{\"digest\":null,\"id\":\"doc\",\"schema\":\"document/v1\"}",
            );
        errdefer allocator.free(document_digest);
        const framed_digest = try testSha256Digest(&.{
            "group/v1\x00",
            "item.txt",
            "\x00",
            test_resource_digest,
            "\x00",
        });
        errdefer allocator.free(framed_digest);
        const field_digest = try testSha256Digest(&.{
            "bundle/v1\x00",
            "owner-1",
            "\x00",
            "parent-1",
            "\x00",
            "subject-1",
            "\x00",
            test_resource_digest,
        });
        errdefer allocator.free(field_digest);
        const transport_digest = try testSha256Digest(
            &.{"example\nrecord\n{}\n"},
        );
        errdefer allocator.free(transport_digest);
        const valid_bytes = try std.fmt.allocPrint(
            allocator,
            "{{\"bundle\":{{\"digest\":\"{s}\",\"document_digest\":\"{s}\"," ++
                "\"owner_id\":\"owner-1\",\"parent_ref\":\"parent-1\"," ++
                "\"subject_ref\":\"subject-1\"}},\"document\":{{\"digest\":" ++
                "\"{s}\",\"id\":\"doc\",\"schema\":\"document/v1\"}}," ++
                "\"groups\":{{\"standard\":{{\"digest\":\"{s}\",\"entries\":" ++
                "[{{\"checksum\":\"{s}\",\"path\":\"item.txt\"}}]}}}}," ++
                "\"transport\":{{\"channel\":\"example\",\"fingerprint\":" ++
                "\"{s}\",\"payload\":\"{{}}\\n\",\"type\":\"record\"}}}}",
            .{
                field_digest,
                test_resource_digest,
                document_digest,
                framed_digest,
                test_resource_digest,
                transport_digest,
            },
        );
        return .{
            .document_digest = document_digest,
            .framed_digest = framed_digest,
            .field_digest = field_digest,
            .transport_digest = transport_digest,
            .valid_bytes = valid_bytes,
        };
    }

    fn deinit(self: *ShaTestVectors) void {
        const allocator = std.testing.allocator;
        allocator.free(self.valid_bytes);
        allocator.free(self.transport_digest);
        allocator.free(self.field_digest);
        allocator.free(self.framed_digest);
        allocator.free(self.document_digest);
        self.* = undefined;
    }
};

fn checkDefinitionReferenceCases(
    definition_plan: *const definition.Plan,
    plan: *const Plan,
) !void {
    const valid_bytes =
        "{\"receipt\":{\"count\":2,\"parent\":null,\"status\":\"complete\"}}";
    var valid = try validate(
        std.testing.allocator,
        definition_plan,
        plan,
        &.{.{ .name = "packet", .bytes = valid_bytes }},
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(valid.valid);
    try std.testing.expect(!valid.authority_granted);
    try std.testing.expect(!valid.storage_mutated);
    try expectTestValidation(
        definition_plan,
        plan,
        "packet",
        "{\"metadata\":{},\"receipt\":{\"count\":2,\"parent\":{\"value\":" ++
            "\"prior\"},\"status\":\"complete\"}}",
        true,
    );
    try expectTestValidation(
        definition_plan,
        plan,
        "packet",
        "{\"receipt\":{\"count\":\"two\",\"parent\":null,\"status\":" ++
            "\"complete\"}}",
        false,
    );
    try expectTestValidation(
        definition_plan,
        plan,
        "packet",
        "{\"other\":{},\"receipt\":{\"count\":2,\"parent\":null,\"status\":" ++
            "\"complete\"}}",
        false,
    );
    try expectTestValidation(
        definition_plan,
        plan,
        "packet",
        "{\"receipt\":{\"count\":2,\"parent\":{\"value\":\"\"},\"status\":" ++
            "\"complete\"}}",
        false,
    );
}

fn expectEmbeddedValues(
    plan: *const Plan,
    event_bytes: []const u8,
    state_bytes: []const u8,
    expected: bool,
) !void {
    var event = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        event_bytes,
        .{},
    );
    defer event.deinit();
    var state = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        state_bytes,
        .{},
    );
    defer state.deinit();
    var result = try executeValues(
        std.testing.allocator,
        plan,
        &.{
            .{ .name = "event", .value = event.value },
            .{ .name = "state", .value = state.value },
        },
    );
    defer result.deinit();
    try std.testing.expectEqual(expected, result.isValid());
}

fn checkEmbeddedValidationCases(
    plan: *const Plan,
    cached: *const Plan,
) !void {
    const replacement =
        "{\"new_refs\":[\"item-1\"],\"operation\":\"replace\"," ++
        "\"stream_id\":\"stream-1\"}";
    const matching =
        "{\"existing_refs\":[],\"phase\":\"open\"," ++
        "\"replacement_allowed\":true,\"stream_id\":\"stream-1\"}";
    const debt =
        "{\"existing_refs\":[\"item-0\"],\"phase\":\"closed\"," ++
        "\"replacement_allowed\":true,\"stream_id\":\"stream-1\"}";
    try expectEmbeddedValues(plan, replacement, matching, true);
    try expectEmbeddedValues(
        plan,
        replacement,
        "{\"existing_refs\":[],\"phase\":\"open\"," ++
            "\"replacement_allowed\":true,\"stream_id\":\"stream-2\"}",
        false,
    );
    try expectEmbeddedValues(
        plan,
        replacement,
        "{\"existing_refs\":[],\"phase\":\"open\"," ++
            "\"replacement_allowed\":false,\"stream_id\":\"stream-1\"}",
        false,
    );
    try expectEmbeddedValues(cached, replacement, debt, false);
    try expectEmbeddedValues(
        cached,
        "{\"new_refs\":[],\"operation\":\"replace\"," ++
            "\"stream_id\":\"stream-1\"}",
        matching,
        false,
    );
    try expectEmbeddedValues(
        cached,
        "{\"operation\":\"inspect\",\"stream_id\":\"stream-1\"}",
        debt,
        true,
    );
}

const validation_test_definition_01 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/record","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object","field-absent","optional-field","scalar-type","enum","safe-identifier","regex","tagged-union","unique","sorted","field-equal","keyed-unique","reference-exists","declared-field-values","disjoint","implies","total-partition","total-mapping","path-format","all","any","none","object-values"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"documents":{"record":{"object":"open","fields":{"schema":{},"record_id":{"scalar":"string","identifier":{"max":64},"regex":{"patterns":["^record-[A-Za-z0-9_.-]+$"],"max":64}},"status":{"enum":["open","closed"]},"tags":{"unique":true,"sorted":true},"mirror":{},"items":{"key":"/id","laws":[["reference-exists",{"path":"/items","reference":"/related_ids","target":"/items","key":"/id","self_reference":"reject"}],["any",{"path":"/items","rules":[["enum",{"path":"/id","values":["item-2"]}]]}],["none",{"path":"/items","rules":[["enum",{"path":"/id","values":["forbidden"]}]]}]],"items":{"object":"exact","fields":{"id":{"scalar":"string"},"kind":{},"state":{},"labels":{"items":{"scalar":"string"},"laws":[["none",{"path":"/labels","rules":[["enum",{"values":["forbidden"]}]]}]]},"related_ids":{}}}},"groups":{"laws":[["path-format",{"path":"/groups","items":"/members","target":"/label","fragments":[{"parent":"/prefix"},{"literal":":"},{"item":"/name"}]}]]},"links":{"laws":[["reference-exists",{"path":"/links","reference":"/item_refs","target":"/items","key":"/id"}],["reference-exists",{"path":"/links","reference":"/optional_target","target":"/items","key":"/id","ignore_null":true}]]},"optional_links":{"laws":[["reference-exists",{"path":"/optional_links","reference":"/item_refs","target":"/items","key":"/id"}]]},"containers":{},"selected":{"laws":[["reference-exists",{"path":"/selected","reference":"","target":"/containers","target_items":"/entries","target_rules":[{"op":"enum","path":"/status","values":["active","inactive"]}],"coverage_rules":[["enum",{"path":"/status","values":["active"]}]],"key":"/id","coverage":"all-targets"}]]},"checks":{},"more_checks":{},"guards":{},"changes":{},"meta":{"values":{"tagged":{"variants":[{"kind":"string","node":{}},{"kind":"object","node":{"object":"exact","fields":{"value":{"scalar":"string"}}}}]}},"fields":{"closure":{"if_present":true,"enum":["confirmed"]}}},"universe":{},"ordering":{"unique":true},"accepted":{},"rejected":{},"targets":{},"mappings":{},"declarations":{},"scored":{},"forbidden":{"forbidden":true},"nullable":{"optional":"nullable","scalar":"string"}}}}},"constraints":{"laws":[["field-equal",{"left":"/status","right":"/mirror"}],["disjoint",{"path":"/links","left":"/expected","right":"/prohibited"}],["implies",{"if":"/status","equals":"closed","then":"/meta/closure","then_nonempty":true}],["implies",{"if":"/changes","nonempty":true,"then":"/meta/transport"}],["reference-exists",{"path":"/accepted","reference":"","target":"/universe","key":""}],["reference-exists",{"path":"/ordering","reference":"","target":"/universe","key":"","coverage":"all-targets"}],["reference-exists",{"sources":[{"path":"/checks","reference":""},{"path":"/more_checks","reference":""},{"path":"/groups","items":"/members","reference":"/target_id"},{"path":"/missing_checks","reference":"","optional":true}],"targets":[{"path":"/items","key":"/id"},{"path":"/groups","items":"/members","fragments":[{"parent":"/prefix"},{"literal":":"},{"item":"/name"}]},{"path":"/missing_groups","key":"","optional":true}]}],["reference-exists",{"sources":[{"path":"/guards","reference":"/ids","rules":[["enum",{"path":"/mode","values":["active"]}]],"fragments":[{"literal":"id:"},{"value":true}]},{"path":"/guards","reference":"/kinds","rules":[["enum",{"path":"/mode","values":["active"]}]],"fragments":[{"literal":"kind:"},{"value":true}]}],"targets":[{"path":"/items","fragments":[{"literal":"id:"},{"item":"/id"}],"coverage_key":"/id"},{"path":"/items","fragments":[{"literal":"kind:"},{"item":"/kind"}],"coverage_key":"/id","match_rules":[["enum",{"path":"/state","values":["ready"]}]]}],"coverage":"all-targets"}],["declared-field-values",{"path":"/scored","object":"/values","declarations":"/declarations","declaration_paths":["/increase","/decrease"],"type":"integer","min":0,"max":100}],["total-partition",{"universe":"/universe","parts":["/accepted","/rejected"]}],["total-mapping",{"source":"/universe","target":"/targets","mapping":"/mappings","from":"/from","to":"/to"}]]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":10,"max_output_bytes":4096,"max_diagnostics":16,"max_reducer_states":16}}
;

const validation_test_definition_02 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/wrapper","owner":"example","imports":[{"id":"example/record","path":"artifact.json"}],"requires":{"abi":"ledger-artifact-abi/v1","operators":["definition-ref"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"documents":{"record":{"definition":"example/record"}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":10,"max_output_bytes":4096,"max_diagnostics":16,"max_reducer_states":16}}
;

const validation_test_definition_03 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/path-policy","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["all","bounded-string","digest","enum","exact-object","one-of","safe-identifier","safe-relative-path"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"documents":{"record":{"object":"exact","fields":{"identity":{"one_of":[{"enum":[null]},{"format":"digest"}]},"label":{"string":{"trimmed_min":1,"max":128}},"paths":{"items":{"relative_path":{"allow_root":true,"reserved_roots":[".git",".ledger"],"case_insensitive_reserved":true}}},"record_id":{"identifier":{"max":128,"style":"lowercase-component"}}}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":16,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
;

const validation_test_definition_04 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/path-scopes","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object","member-of","not-member-of","path-scope-disjoint","path-scope-subset"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"documents":{"record":{"object":"exact","fields":{"allowed":{},"choices":{},"paths":{},"prohibited":{},"selection":{}}}}},"constraints":{"laws":[["path-scope-subset",{"left":"/paths","right":"/allowed"}],["path-scope-disjoint",{"left":"/paths","right":"/prohibited"}],["member-of",{"left":"/selection","right":"/choices"}],["not-member-of",{"left":"/selection","right":"/prohibited"}]]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
;

const validation_test_definition_05 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/input","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":[]},"inputs":{"record":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":1024,"max_records":1,"max_output_bytes":1024,"max_diagnostics":8,"max_reducer_states":1}}
;

const validation_test_definition_06 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/field-count","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["at-least-one","enum","exactly-one"]},"inputs":{"record":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{"documents":{"record":{"laws":[["at-least-one",{"paths":["/first","/second","/third"],"rules":[["enum",{"values":["blocked"]}]]}],["exactly-one",{"paths":["/left","/right"],"rules":[["enum",{"values":["selected"]}]]}]]}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":1024,"max_records":8,"max_output_bytes":1024,"max_diagnostics":8,"max_reducer_states":1}}
;

const validation_test_definition_07 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/correspondence","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["at-least-one","enum","exactly-one","keyed-join","predecessor-successor","sorted"]},"inputs":{"record":{"codec":"json","max_bytes":8192}},"canonicalization":{},"shape":{"documents":{"record":{"fields":{"successors":{"sorted":{"key":"/id"}},"candidates":{"laws":[["exactly-one",{"path":"/candidates","rules":[["enum",{"path":"/status","values":["selected"]}]]}],["at-least-one",{"path":"/candidates","rules":[["enum",{"path":"/derivation","values":["independent"]}]]}]]}}}}},"constraints":{"laws":[["keyed-join",{"collection":"/candidates","key":"/id","selector":"/selected_id","value":"/factors","equals":"/surface","rules":[["enum",{"path":"/status","values":["selected"]}]]}],["predecessor-successor",{"predecessor":"/predecessors","predecessor_key":"/id","successor":"/successors","successor_key":"/id","preserved":"/preserved","retired":"/retired","introduced":"/introduced","mappings":"/mappings","mapping_predecessors":"/from","mapping_successors":"/to"}]]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":8192,"max_store_bytes":8192,"max_records":32,"max_output_bytes":8192,"max_diagnostics":16,"max_reducer_states":1}}
;

const validation_test_definition_08 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/namespaces","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["keyed-unique","reference-exists","tagged-union"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"documents":{"record":{"laws":[["keyed-unique",{"sources":[{"path":"/first","key":"/id"},{"path":"/second","key":"/name"}]}]],"tagged":{"tag":"/mode","variants":[{"value":"expanded","node":{"fields":{"introduced":{"laws":[["reference-exists",{"path":"/introduced","reference":"","target":"/additions","key":"/id","coverage":"all-targets"}]]}}}},{"value":"plain","node":{}}]}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":16,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
;

const validation_test_definition_09 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/digests","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["object-values","sha256"]},"inputs":{"record":{"codec":"json","max_bytes":8192}},"canonicalization":{},"shape":{"documents":{"record":{"fields":{"document":{"sha256":{"mode":"canonical-json-null","field":"/digest","null":"/digest","max_bytes":4096}},"groups":{"values":{"sha256":{"mode":"framed-items","field":"/digest","items":"/entries","prefix":"group/v1\u0000","fragments":[{"item":"/path"},{"literal":"\u0000"},{"item":"/checksum"},{"literal":"\u0000"}],"max_bytes":4096}}},"bundle":{"sha256":{"mode":"framed-fields","field":"/digest","prefix":"bundle/v1\u0000","fragments":[{"parent":"/owner_id"},{"literal":"\u0000"},{"parent":"/parent_ref"},{"literal":"\u0000"},{"parent":"/subject_ref"},{"literal":"\u0000"},{"parent":"/document_digest"}],"max_bytes":4096}},"transport":{"sha256":{"mode":"framed-fields","field":"/fingerprint","prefix":"","fragments":[{"parent":"/channel"},{"literal":"\n"},{"parent":"/type"},{"literal":"\n"},{"parent":"/payload"}],"max_bytes":4096}}}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":8192,"max_store_bytes":8192,"max_records":16,"max_output_bytes":8192,"max_diagnostics":8,"max_reducer_states":1}}
;

const validation_test_definition_10 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/receipt","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["bounded-string","compare-and-append","exact-object","enum","scalar-type","tagged-union"]},"inputs":{"receipt":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{"documents":{"receipt":{"object":"exact","fields":{"count":{"scalar":"integer"},"parent":{"tagged":{"variants":[{"kind":"null","node":{}},{"kind":"object","node":{"object":"exact","fields":{"value":{"string":{"trimmed_min":1,"max":128}}}}}]}},"status":{"enum":["complete"]}}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/receipts.jsonl","kind":"event-log","codec":"jsonl","max_bytes":4096}}},"operations":{"append":{"effects":[{"op":"compare-and-append","slot":"events","input":"receipt"}]}},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":4096,"max_records":4,"max_output_bytes":1024,"max_diagnostics":8,"max_reducer_states":1}}
;

const validation_test_definition_11 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/packet","owner":"example","imports":[{"id":"example/receipt","path":"receipt.json"}],"requires":{"abi":"ledger-artifact-abi/v1","operators":["definition-ref","exact-object"]},"inputs":{"packet":{"codec":"json","max_bytes":2048}},"canonicalization":{},"shape":{"documents":{"packet":{"object":"closed","fields":{"receipt":{"definition":"example/receipt"},"metadata":{"optional":true}}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":2048,"max_store_bytes":2048,"max_records":4,"max_output_bytes":2048,"max_diagnostics":8,"max_reducer_states":1}}
;

const validation_test_definition_12 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/identifier","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["bounded-string"]},"inputs":{"value":{"codec":"json","max_bytes":16}},"canonicalization":{},"shape":{"documents":{"value":{"string":{"min":3,"max":3}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":16,"max_store_bytes":16,"max_records":1,"max_output_bytes":16,"max_diagnostics":4,"max_reducer_states":1}}
;

const validation_test_definition_13 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/identifier-list","owner":"example","imports":[{"id":"example/identifier","path":"identifier.json"}],"requires":{"abi":"ledger-artifact-abi/v1","operators":["all","definition-ref"]},"inputs":{"values":{"codec":"json","max_bytes":128}},"canonicalization":{},"shape":{"documents":{"values":{"items":{"definition":"example/identifier"}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":128,"max_store_bytes":128,"max_records":8,"max_output_bytes":128,"max_diagnostics":8,"max_reducer_states":1}}
;

const validation_test_definition_14 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/record-set","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object","keyed-unique"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"documents":{"record":{"object":"exact","fields":{"left":{},"right":{}}}}},"constraints":{"laws":[["keyed-unique",{"sources":[{"path":"/left","key":"/id"},{"path":"/right","key":"/id"}]}]]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":8,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
;

const validation_test_definition_15 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/wrapper","owner":"example","imports":[{"id":"example/record-set","path":"record.json"}],"requires":{"abi":"ledger-artifact-abi/v1","operators":["definition-ref","exact-object"]},"inputs":{"wrapper":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"documents":{"wrapper":{"object":"exact","fields":{"record":{"definition":"example/record-set"}}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":8,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
;

const validation_test_definition_16 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/no-sensitive-keys","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object","forbidden-object-keys"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"documents":{"record":{"object":"exact","fields":{"payload":{}},"forbidden_keys":{"keys":["api_key","password","secret"],"case_insensitive":true,"max_depth":4,"max_nodes":16}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":16,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
;

const validation_test_definition_17 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/embedded","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["bounded-array","cross-input-equal","enum","implies"]},"inputs":{"event":{"codec":"json","required":false,"max_bytes":4096},"state":{"codec":"json","required":false,"max_bytes":4096}},"canonicalization":{},"shape":{},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":8192,"max_store_bytes":8192,"max_records":8,"max_output_bytes":8192,"max_diagnostics":8,"max_reducer_states":2}}
;

const multi_input_receipt_definition =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/decision-receipt","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["cross-input-equal","exact-object","reference-exists","sha256"]},"inputs":{"contract":{"codec":"json","required":true,"max_bytes":4096},"receipt":{"codec":"json","required":true,"max_bytes":4096}},"canonicalization":{},"shape":{"documents":{"contract":{"object":"exact","fields":{"routes":{},"skill":{},"triggers":{}}},"receipt":{"object":"exact","fields":{"fingerprint":{},"route":{},"skill":{},"trigger_refs":{}}}}},"constraints":{"laws":[["cross-input-equal",{"input":"receipt","left_input":"receipt","left":"/skill","right_input":"contract","right":"/skill"}],["reference-exists",{"input":"receipt","sources":[{"path":"","reference":"/route","singleton":true}],"target_input":"contract","targets":[{"path":"/routes","key":"/id"}]}],["reference-exists",{"input":"receipt","path":"/trigger_refs","reference":"","target_input":"contract","target":"/triggers","key":""}],["sha256",{"input":"contract","path":"","mode":"canonical-json","field_input":"receipt","field":"/fingerprint","allow_bare":true,"max_bytes":4096}]]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":8192,"max_store_bytes":8192,"max_records":16,"max_output_bytes":8192,"max_diagnostics":8,"max_reducer_states":1}}
;

const multi_input_receipt_wrapper_definition =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/receipt-wrapper","owner":"example","imports":[{"id":"example/decision-receipt","path":"receipt.json"}],"requires":{"abi":"ledger-artifact-abi/v1","operators":["definition-ref"]},"inputs":{"contract":{"codec":"json","required":true,"max_bytes":4096},"receipt":{"codec":"json","required":true,"max_bytes":4096}},"canonicalization":{},"shape":{},"constraints":{"laws":[["definition-ref",{"input":"receipt","path":"","definition":"example/decision-receipt","inputs":{"contract":"contract","receipt":"$self"}}]]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":8192,"max_store_bytes":8192,"max_records":16,"max_output_bytes":8192,"max_diagnostics":8,"max_reducer_states":1}}
;

const bare_digest_test_definition =
    \\{
    \\  "schema":"ledger-artifact-definition/v1",
    \\  "id":"example/digest-representations",
    \\  "owner":"example",
    \\  "requires":{"abi":"ledger-artifact-abi/v1","operators":["digest","exact-object"]},
    \\  "inputs":{"record":{"codec":"json","max_bytes":256}},
    \\  "canonicalization":{},
    \\  "shape":{"documents":{"record":{"object":"exact","fields":{
    \\    "strict":{"format":"digest"},
    \\    "flexible":{"format":{"kind":"digest","allow_bare":true}}
    \\  }}}},
    \\  "constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},
    \\  "operations":{},"projections":{},
    \\  "bounds":{"max_input_bytes":256,"max_store_bytes":256,"max_records":1,
    \\    "max_output_bytes":256,"max_diagnostics":4,"max_reducer_states":1}
    \\}
;

const validation_test_definition_18 =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/item-implication","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["bounded-string","enum","implies","tagged-union"]},"inputs":{"record":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{"documents":{"record":{"tagged":{"tag":"/kind","variants":[{"value":"capture","node":{"laws":[["implies",{"if":"/status","equals":"active","rules":[["bounded-string",{"path":"/proof","trimmed_min":1,"max":128}]]}]]}},{"value":"status","node":{"fields":{"status":{"enum":["closed"]}}}}]}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":1024,"max_records":8,"max_output_bytes":1024,"max_diagnostics":8,"max_reducer_states":1}}
;

const path_scope_valid_cases = [_][]const u8{
    "{\"allowed\":[\"src\"],\"choices\":[\"inspect\",\"edit\"],\"paths\":[\"s" ++
        "rc/file.zig\"],\"prohibited\":[\"docs\"],\"selection\":\"inspect\"}",
    "{\"allowed\":[\".\"],\"choices\":[1,2],\"paths\":[\"src\"],\"prohibited" ++
        "\":[],\"selection\":2}",
    "{\"allowed\":[\"src\",\"tests\"],\"choices\":[true],\"paths\":[],\"prohi" ++
        "bited\":[\".git\"],\"selection\":true}",
};

const path_scope_invalid_cases = [_][]const u8{
    "{\"allowed\":[\"src\"],\"choices\":[\"inspect\"],\"paths\":[\"vendor/fil" ++
        "e\"],\"prohibited\":[],\"selection\":\"inspect\"}",
    "{\"allowed\":[\"src\"],\"choices\":[\"inspect\"],\"paths\":[\"src/file\"" ++
        "],\"prohibited\":[\"inspect\"],\"selection\":\"inspect\"}",
    "{\"allowed\":[\"src\"],\"choices\":[\"inspect\"],\"paths\":[\"src\"],\"p" ++
        "rohibited\":[\"src/generated\"],\"selection\":\"inspect\"}",
    "{\"allowed\":[\"src\",\"bad/../scope\"],\"choices\":[\"inspect\"],\"path" ++
        "s\":[\"src/file\"],\"prohibited\":[],\"selection\":\"inspect\"}",
    "{\"allowed\":[\".\"],\"choices\":[\"inspect\"],\"paths\":[\"a\",\"b\",\"" ++
        "c\",\"d\",\"e\"],\"prohibited\":[],\"selection\":\"inspect\"}",
    "{\"allowed\":[\"src\"],\"choices\":[\"inspect\"],\"paths\":[\"src/file\"" ++
        "],\"prohibited\":[],\"selection\":\"edit\"}",
    "{\"allowed\":[\"src\"],\"choices\":[\"inspect\",{}],\"paths\":[\"src/fil" ++
        "e\"],\"prohibited\":[],\"selection\":\"inspect\"}",
};

const correspondence_valid_bytes =
    \\{"candidates":[{"derivation":"independent","factors":["factor-a"],
    \\"id":"candidate-a","status":"selected"},{"derivation":"relative","factors":[
    \\"factor-b"],"id":"candidate-b","status":"dominated"}],"introduced":[
    \\"factor-c"],"mappings":[],"predecessors":[{"id":"factor-a","value":"same"},{
    \\"id":"factor-b","value":"old"}],"preserved":["factor-a"],"retired":[
    \\"factor-b"],"selected_id":"candidate-a","successors":[{"id":"factor-a",
    \\"value":"same"},{"id":"factor-c","value":"new"}],"surface":["factor-a"]}
;

const correspondence_invalid_cases = [_][]const u8{
    "{\"candidates\":[{\"derivation\":\"independent\",\"factors\":[\"factor-a" ++
        "\"],\"id\":\"candidate-a\",\"status\":\"selected\"},{\"derivation\":\"re" ++
        "lative\",\"factors\":[\"factor-b\"],\"id\":\"candidate-b\",\"status\":\"" ++
        "selected\"}],\"introduced\":[\"factor-c\"],\"mappings\":[],\"predecessor" ++
        "s\":[{\"id\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-b\",\"val" ++
        "ue\":\"old\"}],\"preserved\":[\"factor-a\"],\"retired\":[\"factor-b\"]," ++
        "\"selected_id\":\"candidate-a\",\"successors\":[{\"id\":\"factor-a\",\"v" ++
        "alue\":\"same\"},{\"id\":\"factor-c\",\"value\":\"new\"}],\"surface\":[" ++
        "\"factor-a\"]}",
    "{\"candidates\":[{\"derivation\":\"independent\",\"factors\":[\"factor-a" ++
        "\"],\"id\":\"candidate-a\",\"status\":\"selected\"},{\"derivation\":\"re" ++
        "lative\",\"factors\":[\"factor-b\"],\"id\":\"candidate-b\",\"status\":\"" ++
        "dominated\"}],\"introduced\":[\"factor-c\"],\"mappings\":[],\"predecesso" ++
        "rs\":[{\"id\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-b\",\"va" ++
        "lue\":\"old\"}],\"preserved\":[\"factor-a\"],\"retired\":[\"factor-b\"]," ++
        "\"selected_id\":\"candidate-b\",\"successors\":[{\"id\":\"factor-a\",\"v" ++
        "alue\":\"same\"},{\"id\":\"factor-c\",\"value\":\"new\"}],\"surface\":[" ++
        "\"factor-b\"]}",
    "{\"candidates\":[{\"derivation\":\"independent\",\"factors\":[\"factor-a" ++
        "\"],\"id\":\"candidate-a\",\"status\":\"selected\"},{\"derivation\":\"re" ++
        "lative\",\"factors\":[\"factor-b\"],\"id\":\"candidate-b\",\"status\":\"" ++
        "dominated\"}],\"introduced\":[\"factor-c\"],\"mappings\":[],\"predecesso" ++
        "rs\":[{\"id\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-b\",\"va" ++
        "lue\":\"old\"}],\"preserved\":[\"factor-a\"],\"retired\":[\"factor-b\"]," ++
        "\"selected_id\":\"candidate-a\",\"successors\":[{\"id\":\"factor-a\",\"v" ++
        "alue\":\"changed\"},{\"id\":\"factor-c\",\"value\":\"new\"}],\"surface\"" ++
        ":[\"factor-a\"]}",
    "{\"candidates\":[{\"derivation\":\"independent\",\"factors\":[\"factor-a" ++
        "\"],\"id\":\"candidate-a\",\"status\":\"selected\"},{\"derivation\":\"re" ++
        "lative\",\"factors\":[\"factor-b\"],\"id\":\"candidate-b\",\"status\":\"" ++
        "dominated\"}],\"introduced\":[],\"mappings\":[],\"predecessors\":[{\"id" ++
        "\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-b\",\"value\":\"old" ++
        "\"}],\"preserved\":[\"factor-a\"],\"retired\":[\"factor-b\"],\"selected_" ++
        "id\":\"candidate-a\",\"successors\":[{\"id\":\"factor-a\",\"value\":\"sa" ++
        "me\"},{\"id\":\"factor-c\",\"value\":\"new\"}],\"surface\":[\"factor-a\"" ++
        "]}",
    "{\"candidates\":[{\"derivation\":\"independent\",\"factors\":[\"factor-a" ++
        "\"],\"id\":\"candidate-a\",\"status\":\"selected\"},{\"derivation\":\"re" ++
        "lative\",\"factors\":[\"factor-b\"],\"id\":\"candidate-b\",\"status\":\"" ++
        "dominated\"}],\"introduced\":[\"factor-c\"],\"mappings\":[],\"predecesso" ++
        "rs\":[{\"id\":\"factor-a\",\"value\":\"same\"},{\"id\":\"factor-b\",\"va" ++
        "lue\":\"old\"}],\"preserved\":[\"factor-a\"],\"retired\":[\"factor-b\"]," ++
        "\"selected_id\":\"candidate-a\",\"successors\":[{\"id\":\"factor-c\",\"v" ++
        "alue\":\"new\"},{\"id\":\"factor-a\",\"value\":\"same\"}],\"surface\":[" ++
        "\"factor-a\"]}",
};

const validation_valid_record_bytes =
    "{\"schema\":\"example/v1\",\"record_id\":\"record-1\",\"status\":\"open" ++
    "\",\"tags\":[\"a\",\"b\"],\"mirror\":\"open\",\"items\":[{\"id\":\"item-" ++
    "1\",\"kind\":\"shared\",\"state\":\"ready\",\"labels\":[\"a\"],\"related" ++
    "_ids\":[\"item-2\"]},{\"id\":\"item-2\",\"kind\":\"shared\",\"state\":\"" ++
    "ready\",\"labels\":[\"b\"],\"related_ids\":[]}],\"groups\":[{\"prefix\":" ++
    "\"g\",\"members\":[{\"name\":\"one\",\"label\":\"g:one\",\"target_id\":" ++
    "\"item-1\"}]}],\"links\":[{\"item_refs\":[\"item-1\",\"item-2\"],\"optio" ++
    "nal_target\":null,\"expected\":[\"a\"],\"prohibited\":[\"b\"]}],\"option" ++
    "al_links\":[{}],\"containers\":[{\"entries\":[{\"id\":\"nested-1\",\"sta" ++
    "tus\":\"active\"},{\"id\":\"nested-2\",\"status\":\"inactive\"},{\"id\":" ++
    "\"nested-3\",\"status\":\"disabled\"}]}],\"selected\":[\"nested-1\"],\"c" ++
    "hecks\":[\"item-1\",\"g:one\"],\"more_checks\":[\"item-2\"],\"guards\":[" ++
    "{\"mode\":\"active\",\"ids\":[],\"kinds\":[\"shared\"]},{\"mode\":\"inac" ++
    "tive\",\"ids\":[],\"kinds\":[\"missing\"]}],\"changes\":[],\"meta\":{}," ++
    "\"universe\":[\"a\",\"b\"],\"ordering\":[\"a\",\"b\"],\"accepted\":[\"a" ++
    "\"],\"rejected\":[\"b\"],\"targets\":[\"x\",\"y\"],\"mappings\":[{\"from" ++
    "\":\"a\",\"to\":\"x\"},{\"from\":\"b\",\"to\":\"y\"}],\"declarations\":[" ++
    "{\"increase\":\"speed\"},{\"decrease\":\"cost\"}],\"scored\":[{\"values" ++
    "\":{\"speed\":90,\"cost\":10,\"undeclared\":999}}],\"nullable\":null,\"e" ++
    "xtension\":\"preserved\"}";

const validation_invalid_record_bytes =
    "{\"schema\":\"example/v1\",\"record_id\":\"bad id\"," ++
    "\"status\":\"closed" ++
    "\",\"tags\":[\"b\",\"a\",\"a\"],\"mirror\":\"open\",\"items\":[{\"id\":" ++
    "\"item-1\",\"labels\":[1,\"forbidden\"],\"related_ids\":[]},{\"id\":\"it" ++
    "em-1\",\"labels\":[],\"related_ids\":[]}],\"groups\":[{\"prefix\":\"g\"," ++
    "\"members\":[{\"name\":\"one\",\"label\":\"g:one\"}]}],\"links\":[{\"ite" ++
    "m_refs\":[\"missing\"],\"optional_target\":null,\"expected\":[\"same\"]," ++
    "\"prohibited\":[\"same\"]}],\"optional_links\":[{}],\"containers\":[{\"e" ++
    "ntries\":[{\"id\":\"nested-1\",\"status\":\"active\"},{\"id\":\"nested-3" ++
    "\",\"status\":\"disabled\"}]}],\"selected\":[\"nested-1\"],\"checks\":[" ++
    "\"item-1\",\"g:one\"],\"more_checks\":[\"item-2\"],\"changes\":[],\"meta" ++
    "\":{},\"universe\":[\"a\",\"b\"],\"ordering\":[\"a\",\"b\"],\"accepted\"" ++
    ":[\"a\",\"b\"],\"rejected\":[\"b\"],\"targets\":[\"x\",\"y\"],\"mappings" ++
    "\":[{\"from\":\"a\",\"to\":\"x\"},{\"from\":\"a\",\"to\":\"y\"}],\"decla" ++
    "rations\":[{\"increase\":\"speed\"},{\"decrease\":\"cost\"}],\"scored\":" ++
    "[{\"values\":{\"speed\":90,\"cost\":10}}],\"extra\":true}";

test "compiled validation plan accepts valid structure and rejects invalid structure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = validation_test_definition_01,
    });
    var test_plan = try ValidationTestPlan.init(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        8 * 1024 * 1024,
    );
    defer test_plan.deinit();
    try test_plan.expectCacheShape();
    try test_plan.checkAllocationFailures();
    try expectValidTestEnvelope(
        &test_plan,
        validation_valid_record_bytes,
    );

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "wrapper.json",
        .data = validation_test_definition_02,
    });
    var wrapper = try ValidationTestPlan.init(
        std.testing.allocator,
        &tmp.dir,
        "wrapper.json",
        8 * 1024 * 1024,
    );
    defer wrapper.deinit();
    try expectTestValidation(
        &wrapper.definition_plan,
        &wrapper.cached,
        "record",
        validation_valid_record_bytes,
        true,
    );

    try expectReplacementValidation(
        &test_plan.definition_plan,
        &test_plan.cached,
        validation_valid_record_bytes,
        "\"record_id\":\"record-1\"",
        "\"record_id\":\"other-1\"",
        false,
    );
    try expectReplacementValidation(
        &wrapper.definition_plan,
        &wrapper.cached,
        validation_valid_record_bytes,
        "\"record_id\":\"record-1\"",
        "\"record_id\":\"other-1\"",
        false,
    );
    try checkShapeValidationVariants(&test_plan, validation_valid_record_bytes);
    try checkReferenceValidationVariants(&test_plan, validation_valid_record_bytes);
    try checkProtocolValidationVariants(&test_plan, validation_valid_record_bytes);

    try checkInvalidDiagnosticSet(&test_plan);
    try test_plan.checkValidationAllocationFailures(
        validation_valid_record_bytes,
    );
}

test "compiled identifier and repository path policies preserve exact boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = validation_test_definition_03,
    });
    var test_plan = try ValidationTestPlan.init(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        8 * 1024 * 1024,
    );
    defer test_plan.deinit();
    try test_plan.checkAllocationFailures();

    var valid = try validate(
        std.testing.allocator,
        &test_plan.definition_plan,
        &test_plan.cached,
        &.{.{
            .name = "record",
            .bytes = "{\"identity\":null,\"label\":\"value\",\"paths\":[\".\",\".github\",\"sr" ++
                "c/lib\"],\"record_id\":\"record-1\"}",
        }},
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(valid.valid);

    var valid_digest = try validate(
        std.testing.allocator,
        &test_plan.definition_plan,
        &test_plan.cached,
        &.{.{
            .name = "record",
            .bytes = "{\"identity\":\"sha256:1111111111111111111111111111111111111111111111111" ++
                "111111111111111\",\"label\":\"value\",\"paths\":[\"src\"],\"record_id\":" ++
                "\"record-1\"}",
        }},
    );
    defer valid_digest.deinit(std.testing.allocator);
    try std.testing.expect(valid_digest.valid);

    const invalid_cases = [_][]const u8{
        "{\"identity\":null,\"label\":\"value\",\"paths\":[\"src\"],\"record_id\":\"Record-1\"}",
        "{\"identity\":null,\"label\":\"value\",\"paths\":[\"src\"],\"record_id\":\".record\"}",
        "{\"identity\":null,\"label\":\"value\",\"paths\":[\".GIT/config\"],\"rec" ++
            "ord_id\":\"record-1\"}",
        "{\"identity\":null,\"label\":\"value\",\"paths\":[\".ledger\"],\"record_" ++
            "id\":\"record-1\"}",
        "{\"identity\":null,\"label\":\"value\",\"paths\":[\"src/../lib\"],\"reco" ++
            "rd_id\":\"record-1\"}",
        "{\"identity\":\"not-a-digest\",\"label\":\"value\",\"paths\":[\"src\"]," ++
            "\"record_id\":\"record-1\"}",
        "{\"identity\":null,\"label\":\" \\t\",\"paths\":[\"src\"],\"record_id\":\"record-1\"}",
    };
    for (invalid_cases) |bytes| {
        var rejected = try validate(
            std.testing.allocator,
            &test_plan.definition_plan,
            &test_plan.cached,
            &.{.{ .name = "record", .bytes = bytes }},
        );
        defer rejected.deinit(std.testing.allocator);
        try std.testing.expect(!rejected.valid);
    }
}

test "compiled digest representation policy accepts bare hex only when declared" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = bare_digest_test_definition,
    });
    var test_plan = try ValidationTestPlan.init(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        1024 * 1024,
    );
    defer test_plan.deinit();
    const prefixed =
        "sha256:1111111111111111111111111111111111111111111111111111111111111111";
    const bare =
        "aA11111111111111111111111111111111111111111111111111111111111111";
    const cases = [_]struct {
        strict: []const u8,
        flexible: []const u8,
        valid: bool,
    }{
        .{ .strict = prefixed, .flexible = prefixed, .valid = true },
        .{ .strict = prefixed, .flexible = bare, .valid = true },
        .{ .strict = bare, .flexible = prefixed, .valid = false },
        .{ .strict = prefixed, .flexible = bare[0..63], .valid = false },
        .{
            .strict = prefixed,
            .flexible = "zA11111111111111111111111111111111111111111111111111111111111111",
            .valid = false,
        },
    };
    for (cases) |case| {
        const bytes = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"strict\":\"{s}\",\"flexible\":\"{s}\"}}",
            .{ case.strict, case.flexible },
        );
        defer std.testing.allocator.free(bytes);
        try expectTestValidation(
            &test_plan.definition_plan,
            &test_plan.plan,
            "record",
            bytes,
            case.valid,
        );
        try expectTestValidation(
            &test_plan.definition_plan,
            &test_plan.cached,
            "record",
            bytes,
            case.valid,
        );
    }
}

test "compiled path scope comparisons preserve hierarchy and bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = validation_test_definition_04,
    });
    var test_plan = try ValidationTestPlan.init(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        8 * 1024 * 1024,
    );
    defer test_plan.deinit();
    try test_plan.checkAllocationFailures();

    for (path_scope_valid_cases) |bytes| {
        var result = try validate(
            std.testing.allocator,
            &test_plan.definition_plan,
            &test_plan.cached,
            &.{.{ .name = "record", .bytes = bytes }},
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.valid);
    }

    for (path_scope_invalid_cases) |bytes| {
        var result = try validate(
            std.testing.allocator,
            &test_plan.definition_plan,
            &test_plan.cached,
            &.{.{ .name = "record", .bytes = bytes }},
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.valid);
    }
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        validateForAllocationFailure,
        .{
            &test_plan.definition_plan,
            &test_plan.plan,
            path_scope_valid_cases[0],
        },
    );
}

test "validation reports missing and malformed inputs without granting authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = validation_test_definition_05,
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

test "count rules apply predicates across declared fields and survive cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = validation_test_definition_06,
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
            .bytes = "{\"first\":\"clear\",\"left\":\"selected\",\"right\":\"rejected\",\"seco" ++
                "nd\":\"blocked\"}",
            .valid = true,
        },
        .{
            .bytes = "{\"first\":\"clear\",\"left\":\"selected\",\"right\":\"rejected\",\"seco" ++
                "nd\":\"clear\"}",
            .valid = false,
        },
        .{
            .bytes = "{\"first\":\"blocked\",\"left\":\"selected\",\"right\":\"selected\"}",
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

test "compiled correspondence rules bind selected values and total successor partitions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = validation_test_definition_07,
    });
    var test_plan = try ValidationTestPlan.init(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        8 * 1024 * 1024,
    );
    defer test_plan.deinit();
    try test_plan.checkAllocationFailures();

    var valid = try validate(
        std.testing.allocator,
        &test_plan.definition_plan,
        &test_plan.cached,
        &.{.{ .name = "record", .bytes = correspondence_valid_bytes }},
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(valid.valid);

    for (correspondence_invalid_cases) |bytes| {
        var rejected = try validate(
            std.testing.allocator,
            &test_plan.definition_plan,
            &test_plan.cached,
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
        .data = validation_test_definition_08,
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
            .bytes = "{\"additions\":[{\"id\":\"factor-new\"}],\"first\":[{\"id\":\"proof-1\"}" ++
                "],\"introduced\":[\"factor-new\"],\"mode\":\"expanded\",\"second\":[{\"n" ++
                "ame\":\"retirement-1\"}]}",
            .valid = true,
        },
        .{
            .bytes = "{\"additions\":[{\"id\":\"factor-new\"}],\"first\":[{\"id\":\"proof-1\"}" ++
                "],\"introduced\":[\"factor-new\"],\"mode\":\"expanded\",\"second\":[{\"n" ++
                "ame\":\"proof-1\"}]}",
            .valid = false,
        },
        .{
            .bytes = "{\"additions\":[],\"first\":[{\"id\":\"proof-1\"}],\"introduced\":[\"fac" ++
                "tor-new\"],\"mode\":\"expanded\",\"second\":[{\"name\":\"retirement-1\"}" ++
                "]}",
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
        .data = validation_test_definition_09,
    });
    var test_plan = try ValidationTestPlan.init(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        8 * 1024 * 1024,
    );
    defer test_plan.deinit();
    try test_plan.checkAllocationFailures();

    var vectors = try ShaTestVectors.init();
    defer vectors.deinit();
    try expectTestValidation(
        &test_plan.definition_plan,
        &test_plan.cached,
        "record",
        vectors.valid_bytes,
        true,
    );

    const wrong_digest =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try expectReplacementValidation(
        &test_plan.definition_plan,
        &test_plan.cached,
        vectors.valid_bytes,
        vectors.document_digest,
        wrong_digest,
        false,
    );
    try expectReplacementValidation(
        &test_plan.definition_plan,
        &test_plan.cached,
        vectors.valid_bytes,
        vectors.framed_digest,
        wrong_digest,
        false,
    );
    try expectReplacementValidation(
        &test_plan.definition_plan,
        &test_plan.cached,
        vectors.valid_bytes,
        vectors.field_digest,
        wrong_digest,
        false,
    );
    try expectReplacementValidation(
        &test_plan.definition_plan,
        &test_plan.cached,
        vectors.valid_bytes,
        vectors.transport_digest,
        wrong_digest,
        false,
    );
    try test_plan.checkValidationAllocationFailures(vectors.valid_bytes);
}

test "definition references preserve transacted validators across caches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "receipt.json",
        .data = validation_test_definition_10,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packet.json",
        .data = validation_test_definition_11,
    });
    var test_plan = try DefinitionReferenceTestPlan.init(
        std.testing.allocator,
        &tmp.dir,
    );
    defer test_plan.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        test_plan.definition_plan.imports.len,
    );
    try std.testing.expectEqualStrings(
        "example/receipt",
        test_plan.definition_plan.imports[0].id,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        test_plan.cached_definition.imports.len,
    );

    try checkDefinitionReferenceCases(&test_plan.cached_definition, &test_plan.cached);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileForAllocationFailure,
        .{&test_plan.cached_definition},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeForAllocationFailure,
        .{test_plan.payload},
    );
}

test "definition references bind reusable multi-input validators" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "receipt.json",
        .data = multi_input_receipt_definition,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packet.json",
        .data = multi_input_receipt_wrapper_definition,
    });
    var test_plan = try ValidationTestPlan.init(
        std.testing.allocator,
        &tmp.dir,
        "packet.json",
        8 * 1024 * 1024,
    );
    defer test_plan.deinit();

    const contract =
        "{\"skill\":\"example\",\"routes\":[{\"id\":\"inspect\"}," ++
        "{\"id\":\"replace\"}],\"triggers\":[\"manual\",\"review\"]}";
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        contract,
        .{},
    );
    defer parsed.deinit();
    const canonical =
        try definition_core.canonical_json.canonicalJsonAlloc(
            std.testing.allocator,
            parsed.value,
        );
    defer std.testing.allocator.free(canonical);
    const digest =
        try definition_core.canonical_json.digestBytesAlloc(
            std.testing.allocator,
            canonical,
        );
    defer std.testing.allocator.free(digest);
    const valid_receipt = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"fingerprint\":\"{s}\",\"route\":\"inspect\"," ++
            "\"skill\":\"example\",\"trigger_refs\":[\"review\"]}}",
        .{digest[7..]},
    );
    defer std.testing.allocator.free(valid_receipt);
    const stale_receipt =
        "{\"fingerprint\":\"0000000000000000000000000000000000000000000000000000000000000000\"," ++
        "\"route\":\"inspect\",\"skill\":\"example\",\"trigger_refs\":[\"review\"]}";
    const unknown_reference = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"fingerprint\":\"{s}\",\"route\":\"missing\"," ++
            "\"skill\":\"example\",\"trigger_refs\":[\"unknown\"]}}",
        .{digest[7..]},
    );
    defer std.testing.allocator.free(unknown_reference);
    const cases = [_]struct {
        receipt: []const u8,
        valid: bool,
    }{
        .{ .receipt = valid_receipt, .valid = true },
        .{ .receipt = stale_receipt, .valid = false },
        .{ .receipt = unknown_reference, .valid = false },
    };
    for (cases) |case| {
        var compiled = try validate(
            std.testing.allocator,
            &test_plan.definition_plan,
            &test_plan.plan,
            &.{
                .{ .name = "contract", .bytes = contract },
                .{ .name = "receipt", .bytes = case.receipt },
            },
        );
        defer compiled.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.valid, compiled.valid);
        var cached = try validate(
            std.testing.allocator,
            &test_plan.definition_plan,
            &test_plan.cached,
            &.{
                .{ .name = "contract", .bytes = contract },
                .{ .name = "receipt", .bytes = case.receipt },
            },
        );
        defer cached.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.valid, cached.valid);
    }
}

test "collection item rules reuse one imported scalar definition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "identifier.json",
        .data = validation_test_definition_12,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "list.json",
        .data = validation_test_definition_13,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "list.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "list.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var plan = try compile(std.testing.allocator, &definition_plan);
    defer plan.deinit(std.testing.allocator);
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
        &.{.{ .name = "values", .bytes = "[\"one\",\"two\"]" }},
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(valid.valid);
    var invalid = try validate(
        std.testing.allocator,
        &definition_plan,
        &cached,
        &.{.{ .name = "values", .bytes = "[\"one\",\"four\"]" }},
    );
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expect(!invalid.valid);
}

test "definition references execute imported cross-record constraints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "record.json",
        .data = validation_test_definition_14,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "wrapper.json",
        .data = validation_test_definition_15,
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

test "forbidden object keys reject bounded nested sensitive fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = validation_test_definition_16,
    });
    var test_plan = try ValidationTestPlan.init(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        8 * 1024 * 1024,
    );
    defer test_plan.deinit();
    try test_plan.checkAllocationFailures();

    var valid = try validate(
        std.testing.allocator,
        &test_plan.definition_plan,
        &test_plan.cached,
        &.{.{
            .name = "record",
            .bytes = "{\"payload\":{\"items\":[{\"token\":\"public\"}]}}",
        }},
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(valid.valid);

    var sensitive = try validate(
        std.testing.allocator,
        &test_plan.definition_plan,
        &test_plan.cached,
        &.{.{
            .name = "record",
            .bytes = "{\"payload\":{\"items\":[{\"SeCrEt\":\"value\"}]}}",
        }},
    );
    defer sensitive.deinit(std.testing.allocator);
    try std.testing.expect(!sensitive.valid);

    var too_deep = try validate(
        std.testing.allocator,
        &test_plan.definition_plan,
        &test_plan.cached,
        &.{.{
            .name = "record",
            .bytes = "{\"payload\":{\"a\":{\"b\":{\"c\":{\"d\":\"value\"}}}}}",
        }},
    );
    defer too_deep.deinit(std.testing.allocator);
    try std.testing.expect(!too_deep.valid);

    var too_many = try validate(
        std.testing.allocator,
        &test_plan.definition_plan,
        &test_plan.cached,
        &.{.{
            .name = "record",
            .bytes = "{\"payload\":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]}",
        }},
    );
    defer too_many.deinit(std.testing.allocator);
    try std.testing.expect(!too_many.valid);
}

test "optional-only exact objects compile an empty required-key set" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[]",
        .{},
    );
    defer parsed.deinit();
    const keys = try parseStringSet(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 0), keys.len);
}

const embedded_validation_rules =
    \\[
    \\  {"op":"cross-input-equal","input":"event","left_input":"event",
    \\"left":"/stream_id","right_input":"state","right":"/stream_id"},
    \\  {"op":"implies","input":"event","if":"/operation","equals":"replace",
    \\"then_input":"state","then":"/replacement_allowed","then_equals":true},
    \\  {"op":"implies","input":"event","if":"/operation","equals":"replace",
    \\"rules":[{"op":"enum","input":"state","path":"/phase","values":["open"]}]},
    \\  {"op":"implies","input":"state","if":"/existing_refs","empty":true,
    \\"rules":[{"op":"bounded-array","input":"event","path":"/new_refs","min":1}]}
    \\]
;

test "embedded validation compares borrowed event and retained state values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = validation_test_definition_17,
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
        embedded_validation_rules,
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
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        256 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(&plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(std.testing.allocator, &decoder);
    defer cached.deinit(std.testing.allocator);
    try decoder.finish();
    try validateEmbeddedCachePlan(&cached, &definition_plan);
    try checkEmbeddedValidationCases(&plan, &cached);
}

test "tagged union item implications compile conditional native rules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = validation_test_definition_18,
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

    const cases = [_]struct { bytes: []const u8, valid: bool }{
        .{
            .bytes = "{\"kind\":\"capture\",\"status\":\"active\",\"proof\":\"receipt\"}",
            .valid = true,
        },
        .{
            .bytes = "{\"kind\":\"capture\",\"status\":\"active\"}",
            .valid = false,
        },
        .{
            .bytes = "{\"kind\":\"capture\",\"status\":\"pending\"}",
            .valid = true,
        },
        .{
            .bytes = "{\"kind\":\"status\",\"status\":\"closed\"}",
            .valid = true,
        },
    };
    for (cases) |case| {
        var result = try validate(
            std.testing.allocator,
            &definition_plan,
            &plan,
            &.{.{ .name = "record", .bytes = case.bytes }},
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.valid, result.valid);
    }
}
