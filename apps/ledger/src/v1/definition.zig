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
    definition_ref,
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
    bind_existing,
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
    declared_field_values,
    field_absent,
    object_values,
    secure_token,

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
            .definition_ref => "definition-ref",
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
            .bind_existing => "bind-existing",
            .exclusive_custody => "exclusive-custody",
            .atomic_transaction => "atomic-transaction",
            .id_lookup => "id-lookup",
            .text_render => "text-render",
            .declared_field_values => "declared-field-values",
            .field_absent => "field-absent",
            .object_values => "object-values",
            .secure_token => "secure-token",
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

    pub fn version(self: Operator) u16 {
        return switch (self) {
            .exact_object => 2,
            .optional_field => 2,
            .reference_exists => 8,
            .implies => 3,
            .sorted => 2,
            .exactly_one, .at_least_one => 2,
            .keyed_unique => 2,
            .regex => 2,
            .sha256 => 3,
            .reducer => 3,
            .compare_append, .bind_existing => 2,
            .event_envelope => 4,
            .cross_input_equal => 2,
            else => 1,
        };
    }

    pub fn supported(self: Operator) bool {
        return switch (self) {
            .exact_object,
            .required_field,
            .field_absent,
            .optional_field,
            .scalar_type,
            .bounded_string,
            .regex,
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
            .total_partition,
            .exactly_one,
            .at_least_one,
            .all_rules,
            .any_rules,
            .no_rules,
            .keyed_unique,
            .keyed_join,
            .reference_exists,
            .field_equal,
            .field_not_equal,
            .cross_input_equal,
            .implies,
            .predecessor_successor,
            .total_mapping,
            .declared_field_values,
            .object_values,
            .secure_token,
            .canonical_json,
            .canonical_text,
            .sha256,
            .content_address,
            .composite_identity,
            .path_format,
            .immutable_document,
            .append_only_log,
            .event_envelope,
            .sequence,
            .previous_digest,
            .body_digest,
            .event_digest,
            .event_kinds,
            .transition_table,
            .reducer,
            .idempotency_key,
            .compare_append,
            .compare_replace,
            .create_new,
            .bind_existing,
            .exclusive_custody,
            .atomic_transaction,
            .replay,
            .filter,
            .select,
            .limit,
            .id_lookup,
            .latest,
            .fold,
            .@"export",
            => true,
            else => false,
        };
    }
};

pub const Codec = enum {
    json,
    jsonl,
    text,

    pub fn parse(text: []const u8) !Codec {
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
    import_index: ?u16 = null,
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
    imports: []Plan,
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
        for (self.imports) |*imported| imported.deinit(allocator);
        allocator.free(self.imports);
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
    imports: []const Plan,
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
                    const import_index = if (operator == .definition_ref)
                        try self.importIndex(try definition_core.json.requiredString(
                            object,
                            "definition",
                        ))
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
                        .import_index = import_index,
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

    fn importIndex(self: Compiler, id: []const u8) !u16 {
        for (self.imports, 0..) |imported, index| {
            if (std.mem.eql(u8, imported.id, id)) return @intCast(index);
        }
        return error.UnknownImportedDefinition;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    closure: *const definition_core.Closure,
    entry_path: []const u8,
) !Plan {
    var compiled_count: usize = 0;
    return compileAtDepth(
        allocator,
        closure,
        entry_path,
        0,
        &compiled_count,
    );
}

fn compileAtDepth(
    allocator: std.mem.Allocator,
    closure: *const definition_core.Closure,
    entry_path: []const u8,
    depth: usize,
    compiled_count: *usize,
) anyerror!Plan {
    if (depth > 32) return error.ImportDepthExceeded;
    compiled_count.* = std.math.add(
        usize,
        compiled_count.*,
        1,
    ) catch return error.TooManyImportedDefinitions;
    if (compiled_count.* > 128) return error.TooManyImportedDefinitions;
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
    const imports = try parseImportedPlans(
        allocator,
        closure,
        entry_path,
        root.get("imports"),
        depth,
        compiled_count,
    );
    errdefer deinitPlans(allocator, imports);

    var compiler = Compiler{
        .allocator = allocator,
        .operator_mask = operator_mask,
        .imports = imports,
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
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const owned_owner = try allocator.dupe(u8, owner);
    errdefer allocator.free(owned_owner);
    return .{
        .id = owned_id,
        .owner = owned_owner,
        .closure_digest = closure.digest,
        .operator_mask = operator_mask,
        .parameter_declarations = parameter_declarations,
        .inputs = inputs,
        .storage_kind = storage_kind,
        .imports = imports,
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

pub fn encodeCache(plan: *const Plan, encoder: *definition_core.cache.Encoder) !void {
    try encoder.writeU16(2);
    try encodeCachePlan(plan, encoder, 0);
}

fn encodeCachePlan(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
    depth: usize,
) !void {
    if (depth > 32) return error.ImportDepthExceeded;
    try encoder.writeBytes(plan.id);
    try encoder.writeBytes(plan.owner);
    try encoder.writeFixed(&plan.closure_digest);
    try encoder.writeU128(plan.operator_mask);
    try definition_core.parameters.encodeCache(
        &plan.parameter_declarations,
        encoder,
    );
    try encoder.writeCount(plan.inputs.len);
    for (plan.inputs) |input| {
        try encoder.writeBytes(input.name);
        try encoder.writeEnum(input.codec);
        try encoder.writeBool(input.required);
        try encoder.writeUsize(input.max_bytes);
    }
    try encoder.writeEnum(plan.storage_kind);
    try encoder.writeCount(plan.imports.len);
    for (plan.imports) |*imported| {
        try encodeCachePlan(imported, encoder, depth + 1);
    }
    try encoder.writeCount(plan.pointers.len);
    for (plan.pointers) |pointer| try encoder.writeBytes(pointer);
    try encoder.writeCount(plan.rules.len);
    for (plan.rules) |rule| {
        try encoder.writeEnum(rule.operator);
        try encoder.writeBool(rule.pointer_id != null);
        if (rule.pointer_id) |pointer_id| try encoder.writeU16(pointer_id);
        try encoder.writeBool(rule.import_index != null);
        if (rule.import_index) |import_index| try encoder.writeU16(import_index);
        try encoder.writeBytes(rule.canonical_config);
    }
    try encodeNamedPlans(plan.operations, encoder);
    try encodeNamedPlans(plan.projections, encoder);
    try encoder.writeUsize(plan.bounds.max_input_bytes);
    try encoder.writeUsize(plan.bounds.max_store_bytes);
    try encoder.writeUsize(plan.bounds.max_records);
    try encoder.writeUsize(plan.bounds.max_output_bytes);
    try encoder.writeUsize(plan.bounds.max_diagnostics);
    try encoder.writeUsize(plan.bounds.max_reducer_states);
    try encoder.writeBytes(plan.canonicalization_json);
    try encoder.writeBytes(plan.identity_json);
    try encoder.writeBytes(plan.storage_json);
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 2) return error.LedgerPlanCacheVersionMismatch;
    var decoded_count: usize = 0;
    return decodeCachePlan(allocator, decoder, 0, &decoded_count);
}

fn decodeCachePlan(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    depth: usize,
    decoded_count: *usize,
) !Plan {
    if (depth > 32) return error.CacheImportDepthExceeded;
    decoded_count.* = std.math.add(
        usize,
        decoded_count.*,
        1,
    ) catch return error.CacheImportCountExceeded;
    if (decoded_count.* > 128) return error.CacheImportCountExceeded;
    const id = try decoder.readBytesAlloc(allocator, 256);
    errdefer allocator.free(id);
    try definition_core.json.safeIdentifier(id, 256);
    const owner = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(owner);
    try definition_core.json.safeIdentifier(owner, 128);
    var closure_digest: [71]u8 = undefined;
    @memcpy(&closure_digest, try decoder.readFixed(closure_digest.len));
    try definition_core.json.digest(&closure_digest);
    const operator_mask = try decoder.readU128();
    var known_operator_mask: u128 = 0;
    inline for (@typeInfo(Operator).@"enum".fields) |field| {
        const operator: Operator = @enumFromInt(field.value);
        if (operator.supported()) {
            known_operator_mask |= operatorBit(operator);
        }
    }
    if ((operator_mask & ~known_operator_mask) != 0) {
        return error.CacheArtifactOperatorInvalid;
    }
    var parameter_declarations = try definition_core.parameters.decodeCache(
        allocator,
        decoder,
    );
    errdefer parameter_declarations.deinit(allocator);
    const inputs = try decodeInputs(allocator, decoder);
    errdefer deinitInputs(allocator, inputs);
    const storage_kind = try decoder.readEnum(StorageKind);
    const import_count = try decoder.readCount(128);
    const imports = try allocator.alloc(Plan, import_count);
    var imports_initialized: usize = 0;
    errdefer {
        for (imports[0..imports_initialized]) |*imported| {
            imported.deinit(allocator);
        }
        allocator.free(imports);
    }
    for (imports) |*imported| {
        imported.* = try decodeCachePlan(
            allocator,
            decoder,
            depth + 1,
            decoded_count,
        );
        imports_initialized += 1;
    }
    try validateImportedPlans(imports);
    const pointers = try decodePointers(allocator, decoder);
    errdefer deinitPointers(allocator, pointers);
    const rules = try decodeRules(
        allocator,
        decoder,
        operator_mask,
        imports.len,
        pointers.len,
    );
    errdefer deinitRules(allocator, rules);
    const operations = try decodeNamedPlans(allocator, decoder, rules.len);
    errdefer deinitNamedPlans(allocator, operations);
    const projections = try decodeNamedPlans(allocator, decoder, rules.len);
    errdefer deinitNamedPlans(allocator, projections);
    const bounds: Bounds = .{
        .max_input_bytes = try decoder.readUsize(),
        .max_store_bytes = try decoder.readUsize(),
        .max_records = try decoder.readUsize(),
        .max_output_bytes = try decoder.readUsize(),
        .max_diagnostics = try decoder.readUsize(),
        .max_reducer_states = try decoder.readUsize(),
    };
    try validateBounds(bounds);
    const canonicalization_json = try decoder.readBytesAlloc(
        allocator,
        4 * 1024 * 1024,
    );
    errdefer allocator.free(canonicalization_json);
    const identity_json = try decoder.readBytesAlloc(
        allocator,
        4 * 1024 * 1024,
    );
    errdefer allocator.free(identity_json);
    const storage_json = try decoder.readBytesAlloc(
        allocator,
        4 * 1024 * 1024,
    );
    errdefer allocator.free(storage_json);
    return .{
        .id = id,
        .owner = owner,
        .closure_digest = closure_digest,
        .operator_mask = operator_mask,
        .parameter_declarations = parameter_declarations,
        .inputs = inputs,
        .storage_kind = storage_kind,
        .imports = imports,
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

fn encodeNamedPlans(
    plans: []const NamedPlan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(plans.len);
    for (plans) |plan| {
        try encoder.writeBytes(plan.name);
        try encoder.writeUsize(plan.rule_start);
        try encoder.writeUsize(plan.rule_count);
        try encoder.writeBytes(plan.canonical_config);
    }
}

fn decodeInputs(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]Input {
    const count = try decoder.readCount(64);
    if (count == 0) return error.InvalidInputCount;
    const inputs = try allocator.alloc(Input, count);
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
        const codec = try decoder.readEnum(Codec);
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

fn decodePointers(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![][]u8 {
    const count = try decoder.readCount(65_535);
    const pointers = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (pointers[0..initialized]) |pointer| allocator.free(pointer);
        allocator.free(pointers);
    }
    for (pointers) |*pointer| {
        pointer.* = try decoder.readBytesAlloc(allocator, 1024);
        errdefer allocator.free(pointer.*);
        try validateJsonPointer(pointer.*);
        initialized += 1;
    }
    return pointers;
}

fn decodeRules(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    operator_mask: u128,
    import_count: usize,
    pointer_count: usize,
) ![]Rule {
    const count = try decoder.readCount(65_535);
    const rules = try allocator.alloc(Rule, count);
    var initialized: usize = 0;
    errdefer {
        for (rules[0..initialized]) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    for (rules) |*rule| {
        const operator = try decoder.readEnum(Operator);
        if ((operator_mask & operatorBit(operator)) == 0) {
            return error.UndeclaredArtifactOperator;
        }
        const pointer_id = if (try decoder.readBool())
            try decoder.readU16()
        else
            null;
        if (pointer_id != null and pointer_id.? >= pointer_count) {
            return error.CachePointerIndexInvalid;
        }
        const import_index = if (try decoder.readBool())
            try decoder.readU16()
        else
            null;
        if (import_index != null and import_index.? >= import_count) {
            return error.CacheImportIndexInvalid;
        }
        if ((operator == .definition_ref) != (import_index != null)) {
            return error.CacheImportIndexInvalid;
        }
        const canonical_config = try decoder.readBytesAlloc(
            allocator,
            4 * 1024 * 1024,
        );
        errdefer allocator.free(canonical_config);
        rule.* = .{
            .operator = operator,
            .pointer_id = pointer_id,
            .import_index = import_index,
            .canonical_config = canonical_config,
        };
        initialized += 1;
    }
    return rules;
}

fn decodeNamedPlans(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    rule_count: usize,
) ![]NamedPlan {
    const count = try decoder.readCount(128);
    const plans = try allocator.alloc(NamedPlan, count);
    var initialized: usize = 0;
    errdefer {
        for (plans[0..initialized]) |*plan| plan.deinit(allocator);
        allocator.free(plans);
    }
    for (plans, 0..) |*plan, index| {
        const name = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(name);
        try definition_core.json.safeIdentifier(name, 128);
        if (index != 0 and
            std.mem.order(u8, plans[index - 1].name, name) != .lt)
        {
            return error.CacheNamedPlansNotSorted;
        }
        const rule_start = try decoder.readUsize();
        const plan_rule_count = try decoder.readUsize();
        const rule_end = std.math.add(
            usize,
            rule_start,
            plan_rule_count,
        ) catch return error.CacheRuleRangeInvalid;
        if (rule_end > rule_count) return error.CacheRuleRangeInvalid;
        const canonical_config = try decoder.readBytesAlloc(
            allocator,
            4 * 1024 * 1024,
        );
        errdefer allocator.free(canonical_config);
        plan.* = .{
            .name = name,
            .rule_start = rule_start,
            .rule_count = plan_rule_count,
            .canonical_config = canonical_config,
        };
        initialized += 1;
    }
    return plans;
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
        if (!operator.supported()) {
            return error.ArtifactOperatorNotImplemented;
        }
        const bit = operatorBit(operator);
        if ((mask & bit) != 0) return error.DuplicateArtifactOperator;
        mask |= bit;
    }
    return mask;
}

fn parseImportedPlans(
    allocator: std.mem.Allocator,
    closure: *const definition_core.Closure,
    entry_path: []const u8,
    raw: ?std.json.Value,
    depth: usize,
    compiled_count: *usize,
) anyerror![]Plan {
    const value = raw orelse return allocator.alloc(Plan, 0);
    const items = try definition_core.json.array(value);
    if (items.items.len > 128) return error.TooManyImportedDefinitions;
    const imports = try allocator.alloc(Plan, items.items.len);
    var initialized: usize = 0;
    errdefer {
        for (imports[0..initialized]) |*imported| imported.deinit(allocator);
        allocator.free(imports);
    }
    const base_dir = std.fs.path.dirname(entry_path) orelse "";
    for (items.items, 0..) |item, index| {
        var declared_id: ?[]const u8 = null;
        const raw_path = switch (item) {
            .string => |path| path,
            .object => |object| blk: {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "id", "path" },
                );
                try definition_core.json.requireFields(
                    object,
                    &.{ "id", "path" },
                );
                declared_id = try definition_core.json.requiredString(
                    object,
                    "id",
                );
                try definition_core.json.safeIdentifier(declared_id.?, 256);
                break :blk try definition_core.json.requiredString(
                    object,
                    "path",
                );
            },
            else => return error.InvalidImports,
        };
        const normalized = try definition_core.closure.normalizeRelativeAlloc(
            allocator,
            base_dir,
            raw_path,
        );
        defer allocator.free(normalized);
        imports[index] = try compileAtDepth(
            allocator,
            closure,
            normalized,
            depth + 1,
            compiled_count,
        );
        initialized += 1;
        if (declared_id) |expected| {
            if (!std.mem.eql(u8, expected, imports[index].id)) {
                return error.ImportedDefinitionIdMismatch;
            }
        }
    }
    std.mem.sort(Plan, imports, {}, struct {
        fn lessThan(_: void, left: Plan, right: Plan) bool {
            return std.mem.lessThan(u8, left.id, right.id);
        }
    }.lessThan);
    try validateImportedPlans(imports);
    return imports;
}

fn validateImportedPlans(imports: []const Plan) !void {
    for (imports, 0..) |imported, index| {
        if (index != 0 and
            std.mem.order(u8, imports[index - 1].id, imported.id) != .lt)
        {
            return error.DuplicateImportedDefinition;
        }
    }
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
        var input: Input = .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .codec = try Codec.parse(try definition_core.json.requiredString(declaration, "codec")),
            .required = if (declaration.get("required")) |raw|
                try definition_core.json.boolean(raw)
            else
                true,
            .max_bytes = max_bytes,
        };
        errdefer input.deinit(allocator);
        try out.append(allocator, input);
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
        var plan: NamedPlan = plan: {
            const name = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(name);
            const canonical_config =
                try definition_core.canonical_json.canonicalJsonAlloc(
                    allocator,
                    entry.value_ptr.*,
                );
            errdefer allocator.free(canonical_config);
            break :plan .{
                .name = name,
                .rule_start = start,
                .rule_count = compiler.rules.items.len - start,
                .canonical_config = canonical_config,
            };
        };
        errdefer plan.deinit(allocator);
        try out.append(allocator, plan);
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
    try validateBounds(bounds);
    return bounds;
}

fn validateBounds(bounds: Bounds) !void {
    if (bounds.max_input_bytes == 0 or bounds.max_input_bytes > 256 * 1024 * 1024 or
        bounds.max_store_bytes == 0 or bounds.max_store_bytes > 4 * 1024 * 1024 * 1024 or
        bounds.max_records == 0 or bounds.max_records > 10_000_000 or
        bounds.max_output_bytes == 0 or bounds.max_output_bytes > 256 * 1024 * 1024 or
        bounds.max_diagnostics == 0 or bounds.max_diagnostics > 1024 or
        bounds.max_reducer_states == 0 or bounds.max_reducer_states > 65_536)
    {
        return error.ArtifactBoundsExceeded;
    }
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

fn deinitPlans(allocator: std.mem.Allocator, plans: []Plan) void {
    for (plans) |*plan| plan.deinit(allocator);
    allocator.free(plans);
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
    try std.testing.expectEqualStrings(plan.id, cached.id);
    try std.testing.expectEqualStrings(plan.owner, cached.owner);
    try std.testing.expectEqualSlices(
        u8,
        &plan.closure_digest,
        &cached.closure_digest,
    );
    try std.testing.expectEqual(plan.operator_mask, cached.operator_mask);
    try std.testing.expectEqual(plan.rules.len, cached.rules.len);
    try std.testing.expectEqual(plan.operations.len, cached.operations.len);
    try std.testing.expectEqual(plan.projections.len, cached.projections.len);
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

test "artifact definition rejects named but unimplemented operators" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/unsupported","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["set-order"]},"inputs":{"record":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":1024,"max_records":1,"max_output_bytes":1024,"max_diagnostics":1,"max_reducer_states":1}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ArtifactOperatorNotImplemented,
        compile(std.testing.allocator, &closure, "artifact.json"),
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
