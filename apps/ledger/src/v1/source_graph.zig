const std = @import("std");
const definition_core = @import("definition_core");

const node_keys = [_][]const u8{
    "object",
    "fields",
    "optional",
    "if_present",
    "required",
    "forbidden",
    "scalar",
    "string",
    "number",
    "array",
    "object_bounds",
    "enum",
    "format",
    "identifier",
    "relative_path",
    "regex",
    "definition",
    "unique",
    "sorted",
    "key",
    "items",
    "values",
    "one_of",
    "tagged",
    "laws",
    "sha256",
    "event_envelope",
    "declared_field_values",
    "forbidden_keys",
};

pub const ExpansionBudget = struct {
    emitted: usize = 0,

    const max_emitted: usize = 65_536;

    fn reserve(self: *ExpansionBudget, count: usize) !void {
        self.emitted = std.math.add(usize, self.emitted, count) catch
            return error.SourceGraphExpansionLimitExceeded;
        if (self.emitted > max_emitted) {
            return error.SourceGraphExpansionLimitExceeded;
        }
    }
};

pub fn lowerShape(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    input_names: []const []const u8,
    budget: *ExpansionBudget,
) !std.json.Value {
    const shape = try definition_core.json.object(raw);
    if (shape.count() == 0) {
        return .{ .array = std.json.Array.init(allocator) };
    }
    try definition_core.json.requireExactKeys(shape, &.{
        "types",
        "documents",
    });
    const types = if (shape.get("types")) |value|
        try definition_core.json.object(value)
    else
        null;
    const documents = try definition_core.json.object(
        try definition_core.json.field(shape, "documents"),
    );
    if (types) |type_map| {
        var used = std.json.ObjectMap.empty;
        var document_iterator = documents.iterator();
        while (document_iterator.next()) |entry| {
            try collectDocumentTypeUses(
                allocator,
                entry.value_ptr.*,
                &used,
                0,
            );
        }
        try requireUsedDeclarationNames(
            type_map,
            used,
            error.UnusedDocumentType,
        );
    }
    var rules = std.json.Array.init(allocator);
    var iterator = documents.iterator();
    while (iterator.next()) |entry| {
        try definition_core.json.safeIdentifier(entry.key_ptr.*, 128);
        if (!containsString(input_names, entry.key_ptr.*)) {
            return error.UnknownDocumentInput;
        }
        try lowerNode(
            allocator,
            &rules,
            entry.value_ptr.*,
            entry.key_ptr.*,
            "",
            false,
            types,
            true,
            budget,
        );
    }
    return .{ .array = rules };
}

pub fn lowerConstraints(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    input_names: []const []const u8,
    budget: *ExpansionBudget,
) !std.json.Value {
    const constraints = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(constraints, &.{
        "terms",
        "scope",
        "laws",
        "event_log",
        "state",
    });
    const terms = if (constraints.get("terms")) |value|
        try definition_core.json.object(value)
    else
        null;
    const scope = if (constraints.get("scope")) |value|
        try definition_core.json.object(value)
    else
        null;
    if (scope) |value| {
        try definition_core.json.requireExactKeys(value, &.{
            "input",
            "path",
        });
        try definition_core.json.requireFields(value, &.{
            "input",
            "path",
        });
        if (!containsString(
            input_names,
            try definition_core.json.requiredString(value, "input"),
        )) {
            return error.UnknownConstraintInput;
        }
    }
    if (terms) |term_map| {
        var use_sites = std.json.ObjectMap.empty;
        if (constraints.get("laws")) |laws| {
            try collectLawTermUses(
                allocator,
                laws,
                &use_sites,
                0,
            );
        }
        if (constraints.get("state")) |raw_state| {
            const state = try definition_core.json.object(raw_state);
            if (state.get("admissions")) |raw_admissions| {
                const admissions = try definition_core.json.array(
                    raw_admissions,
                );
                for (admissions.items) |raw_admission| {
                    const admission = try definition_core.json.object(
                        raw_admission,
                    );
                    if (admission.get("laws")) |laws| {
                        try collectLawTermUses(
                            allocator,
                            laws,
                            &use_sites,
                            0,
                        );
                    }
                }
            }
        }
        try requireUsedDeclarationNames(
            term_map,
            use_sites,
            error.UnusedLawTerm,
        );
    }
    var rules = std.json.Array.init(allocator);
    if (constraints.get("laws")) |raw_laws| {
        var lowered = try lowerExpressions(
            allocator,
            try definition_core.json.array(raw_laws),
            if (scope) |value|
                try definition_core.json.requiredString(value, "input")
            else
                null,
            if (scope) |value|
                try definition_core.json.requiredString(value, "path")
            else
                null,
            terms,
            true,
            budget,
        );
        defer lowered.deinit();
        try rules.appendSlice(lowered.items);
    }
    if (constraints.get("event_log")) |event_log| {
        try lowerEventLog(allocator, &rules, event_log, budget);
    }
    if (constraints.get("state")) |state| {
        try appendRule(
            budget,
            &rules,
            try lowerState(allocator, state, terms, budget),
        );
    }
    return .{ .array = rules };
}

pub fn lowerOperations(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    budget: *ExpansionBudget,
) !std.json.Value {
    const operations = try definition_core.json.object(raw);
    const raw_event = operations.get("$event") orelse
        return .{ .object = operations };
    var plans = std.json.ObjectMap.empty;
    var iterator = operations.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "$event")) continue;
        try plans.put(
            allocator,
            entry.key_ptr.*,
            entry.value_ptr.*,
        );
    }
    return .{
        .object = try lowerEventOperations(
            allocator,
            try definition_core.json.object(raw_event),
            plans,
            budget,
        ),
    };
}

fn documentNodeObject(
    raw: std.json.Value,
    types: ?std.json.ObjectMap,
    allow_types: bool,
) !std.json.ObjectMap {
    if (raw != .array) return definition_core.json.object(raw);
    const reference = try definition_core.json.array(raw);
    if (!allow_types or reference.items.len != 2 or
        !std.mem.eql(
            u8,
            try definition_core.json.string(reference.items[0]),
            "use",
        ))
    {
        return error.InvalidDocumentTypeReference;
    }
    const name = try definition_core.json.string(reference.items[1]);
    const type_map = types orelse return error.UnknownDocumentType;
    const definition = type_map.get(name) orelse
        return error.UnknownDocumentType;
    if (definition == .array) return error.NestedDocumentTypeReference;
    return definition_core.json.object(definition);
}

fn lowerNode(
    allocator: std.mem.Allocator,
    rules: *std.json.Array,
    raw: std.json.Value,
    input: ?[]const u8,
    path: []const u8,
    suppress_presence: bool,
    types: ?std.json.ObjectMap,
    allow_types: bool,
    budget: *ExpansionBudget,
) anyerror!void {
    if (raw == .array) {
        const reference = try definition_core.json.array(raw);
        if (!allow_types or reference.items.len != 2 or
            !std.mem.eql(
                u8,
                try definition_core.json.string(reference.items[0]),
                "use",
            ))
        {
            return error.InvalidDocumentTypeReference;
        }
        const name = try definition_core.json.string(reference.items[1]);
        const type_map = types orelse return error.UnknownDocumentType;
        const definition = type_map.get(name) orelse
            return error.UnknownDocumentType;
        return lowerNode(
            allocator,
            rules,
            definition,
            input,
            path,
            suppress_presence,
            types,
            false,
            budget,
        );
    }
    const node = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(node, &node_keys);

    if (!suppress_presence) {
        if (try optionalBool(node, "forbidden", false)) {
            try appendRule(
                budget,
                rules,
                try makeRule(allocator, "field-absent", input, path, null),
            );
            return;
        }
        const presence = try optionalPresence(node);
        const if_present = try ifPresentPresence(node);
        if (presence != .required or if_present != .required) {
            var children = std.json.Array.init(allocator);
            try lowerNode(
                allocator,
                &children,
                raw,
                null,
                "",
                true,
                types,
                allow_types,
                budget,
            );
            if (children.items.len == 0) {
                children.deinit();
                return;
            }
            var config = std.json.ObjectMap.empty;
            try config.put(allocator, "rules", .{ .array = children });
            if (presence == .nullable or if_present == .nullable) {
                try config.put(
                    allocator,
                    "allow_null",
                    .{ .bool = true },
                );
            }
            try appendRule(
                budget,
                rules,
                try makeRule(
                    allocator,
                    "optional-field",
                    input,
                    path,
                    .{ .object = config },
                ),
            );
            return;
        }
        if (try optionalBool(node, "required", false)) {
            try appendRule(
                budget,
                rules,
                try makeRule(allocator, "required-field", input, path, null),
            );
            try lowerNode(
                allocator,
                rules,
                raw,
                input,
                path,
                true,
                types,
                allow_types,
                budget,
            );
            return;
        }
    }

    if (node.get("object")) |raw_object| {
        try appendRule(
            budget,
            rules,
            try lowerObjectRule(
                allocator,
                node,
                input,
                path,
                try definition_core.json.string(raw_object),
                types,
                allow_types,
            ),
        );
    }
    if (node.get("scalar")) |raw_scalar| {
        var config = std.json.ObjectMap.empty;
        try config.put(allocator, "type", raw_scalar);
        try appendRule(
            budget,
            rules,
            try makeRule(
                allocator,
                "scalar-type",
                input,
                path,
                .{ .object = config },
            ),
        );
    }
    if (node.get("string")) |config| {
        try appendRule(
            budget,
            rules,
            try makeRule(allocator, "bounded-string", input, path, config),
        );
    }
    if (node.get("number")) |config| {
        try appendRule(
            budget,
            rules,
            try makeRule(allocator, "bounded-number", input, path, config),
        );
    }
    if (node.get("array")) |config| {
        try appendRule(
            budget,
            rules,
            try makeRule(allocator, "bounded-array", input, path, config),
        );
    }
    if (node.get("object_bounds")) |config| {
        try appendRule(
            budget,
            rules,
            try makeRule(allocator, "bounded-object", input, path, config),
        );
    }
    if (node.get("enum")) |values| {
        var config = std.json.ObjectMap.empty;
        try config.put(allocator, "values", values);
        try appendRule(
            budget,
            rules,
            try makeRule(
                allocator,
                "enum",
                input,
                path,
                .{ .object = config },
            ),
        );
    }
    if (node.get("format")) |raw_format| {
        const format = try definition_core.json.string(raw_format);
        if (!std.mem.eql(u8, format, "digest") and
            !std.mem.eql(u8, format, "timestamp"))
        {
            return error.UnsupportedDocumentFormat;
        }
        try appendRule(
            budget,
            rules,
            try makeRule(allocator, format, input, path, null),
        );
    }
    if (node.get("identifier")) |config| {
        try appendRule(
            budget,
            rules,
            try makeRule(
                allocator,
                "safe-identifier",
                input,
                path,
                boolAsEmptyObject(config),
            ),
        );
    }
    if (node.get("relative_path")) |config| {
        try appendRule(
            budget,
            rules,
            try makeRule(
                allocator,
                "safe-relative-path",
                input,
                path,
                boolAsEmptyObject(config),
            ),
        );
    }
    if (node.get("regex")) |config| {
        try appendRule(
            budget,
            rules,
            try makeRule(allocator, "regex", input, path, config),
        );
    }
    if (node.get("definition")) |raw_definition| {
        var config = std.json.ObjectMap.empty;
        try config.put(allocator, "definition", raw_definition);
        try appendRule(
            budget,
            rules,
            try makeRule(
                allocator,
                "definition-ref",
                input,
                path,
                .{ .object = config },
            ),
        );
    }
    if (try optionalBool(node, "unique", false)) {
        try appendRule(
            budget,
            rules,
            try makeRule(allocator, "unique", input, path, null),
        );
    }
    if (node.get("sorted")) |config| {
        try appendRule(
            budget,
            rules,
            try makeRule(
                allocator,
                "sorted",
                input,
                path,
                boolAsEmptyObject(config),
            ),
        );
    }
    if (node.get("key")) |raw_key| {
        var config = std.json.ObjectMap.empty;
        try config.put(allocator, "key", raw_key);
        try appendRule(
            budget,
            rules,
            try makeRule(
                allocator,
                "keyed-unique",
                input,
                path,
                .{ .object = config },
            ),
        );
    }
    if (node.get("items")) |items| {
        var children = std.json.Array.init(allocator);
        try lowerNode(
            allocator,
            &children,
            items,
            null,
            "",
            false,
            types,
            allow_types,
            budget,
        );
        var config = std.json.ObjectMap.empty;
        try config.put(allocator, "rules", .{ .array = children });
        try appendRule(
            budget,
            rules,
            try makeRule(
                allocator,
                "all",
                input,
                path,
                .{ .object = config },
            ),
        );
    }
    if (node.get("values")) |values| {
        var children = std.json.Array.init(allocator);
        try lowerNode(
            allocator,
            &children,
            values,
            null,
            "",
            false,
            types,
            allow_types,
            budget,
        );
        var config = std.json.ObjectMap.empty;
        try config.put(allocator, "rules", .{ .array = children });
        try appendRule(
            budget,
            rules,
            try makeRule(
                allocator,
                "object-values",
                input,
                path,
                .{ .object = config },
            ),
        );
    }
    if (node.get("one_of")) |raw_variants| {
        const variants = try definition_core.json.array(raw_variants);
        var lowered = std.json.Array.init(allocator);
        for (variants.items) |variant| {
            var variant_rules = std.json.Array.init(allocator);
            try lowerNode(
                allocator,
                &variant_rules,
                variant,
                null,
                "",
                false,
                types,
                allow_types,
                budget,
            );
            if (variant_rules.items.len != 1) {
                return error.InvalidOneOfDocumentVariant;
            }
            try lowered.append(variant_rules.items[0]);
        }
        var config = std.json.ObjectMap.empty;
        try config.put(allocator, "rules", .{ .array = lowered });
        try appendRule(
            budget,
            rules,
            try makeRule(
                allocator,
                "one-of",
                input,
                path,
                .{ .object = config },
            ),
        );
    }
    if (node.get("tagged")) |raw_tagged| {
        try appendRule(
            budget,
            rules,
            try lowerTaggedRule(
                allocator,
                raw_tagged,
                input,
                path,
                types,
                allow_types,
                budget,
            ),
        );
    }
    inline for (.{
        .{ "sha256", "sha256" },
        .{ "declared_field_values", "declared-field-values" },
        .{ "forbidden_keys", "forbidden-object-keys" },
    }) |entry| {
        if (node.get(entry[0])) |config| {
            try appendRule(
                budget,
                rules,
                try makeRule(allocator, entry[1], input, path, config),
            );
        }
    }
    if (node.get("event_envelope")) |config| {
        if (path.len != 0) return error.EventEnvelopeMustBeDocumentRoot;
        try appendRule(
            budget,
            rules,
            try makeRule(allocator, "event-envelope", input, null, config),
        );
    }
    if (node.get("laws")) |raw_laws| {
        const laws = try definition_core.json.array(raw_laws);
        var lowered = try lowerExpressions(
            allocator,
            laws,
            input,
            path,
            null,
            false,
            budget,
        );
        defer lowered.deinit();
        try rules.appendSlice(lowered.items);
    }

    if (node.get("fields")) |raw_fields| {
        const fields = try definition_core.json.object(raw_fields);
        var iterator = fields.iterator();
        while (iterator.next()) |entry| {
            const child_path = try joinPointer(
                allocator,
                path,
                entry.key_ptr.*,
            );
            try lowerNode(
                allocator,
                rules,
                entry.value_ptr.*,
                input,
                child_path,
                false,
                types,
                allow_types,
                budget,
            );
        }
    }
}

fn lowerObjectRule(
    allocator: std.mem.Allocator,
    node: std.json.ObjectMap,
    input: ?[]const u8,
    path: []const u8,
    mode: []const u8,
    types: ?std.json.ObjectMap,
    allow_types: bool,
) !std.json.Value {
    if (!std.mem.eql(u8, mode, "exact") and
        !std.mem.eql(u8, mode, "closed") and
        !std.mem.eql(u8, mode, "open"))
    {
        return error.InvalidDocumentObjectMode;
    }
    var required = std.json.Array.init(allocator);
    var optional = std.json.Array.init(allocator);
    if (node.get("fields")) |raw_fields| {
        const fields = try definition_core.json.object(raw_fields);
        var iterator = fields.iterator();
        while (iterator.next()) |entry| {
            const field = try documentNodeObject(
                entry.value_ptr.*,
                types,
                allow_types,
            );
            if (try optionalBool(field, "forbidden", false)) continue;
            if (try optionalPresence(field) != .required) {
                try optional.append(.{ .string = entry.key_ptr.* });
            } else {
                try required.append(.{ .string = entry.key_ptr.* });
            }
        }
    }
    var config = std.json.ObjectMap.empty;
    if (std.mem.eql(u8, mode, "exact")) {
        if (optional.items.len != 0) {
            return error.ExactObjectCannotDeclareOptionalFields;
        }
        try config.put(allocator, "keys", .{ .array = required });
        optional.deinit();
    } else {
        try config.put(allocator, "required_keys", .{ .array = required });
        try config.put(allocator, "optional_keys", .{ .array = optional });
        try config.put(allocator, "allow_additional", .{
            .bool = std.mem.eql(u8, mode, "open"),
        });
    }
    return makeRule(
        allocator,
        "exact-object",
        input,
        path,
        .{ .object = config },
    );
}

fn lowerTaggedRule(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    input: ?[]const u8,
    path: []const u8,
    types: ?std.json.ObjectMap,
    allow_types: bool,
    budget: *ExpansionBudget,
) anyerror!std.json.Value {
    const tagged = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(tagged, &.{
        "tag",
        "variants",
    });
    var config = std.json.ObjectMap.empty;
    if (tagged.get("tag")) |tag| {
        try config.put(allocator, "tag", tag);
    }
    const raw_variants = try definition_core.json.array(
        try definition_core.json.field(tagged, "variants"),
    );
    var variants = std.json.Array.init(allocator);
    for (raw_variants.items) |raw_variant| {
        const variant = try definition_core.json.object(raw_variant);
        try definition_core.json.requireExactKeys(variant, &.{
            "value",
            "kind",
            "node",
        });
        const value = variant.get("value");
        const kind = variant.get("kind");
        if ((value == null) == (kind == null)) {
            return error.InvalidTaggedDocumentVariant;
        }
        var lowered_rules = std.json.Array.init(allocator);
        try lowerNode(
            allocator,
            &lowered_rules,
            try definition_core.json.field(variant, "node"),
            null,
            "",
            false,
            types,
            allow_types,
            budget,
        );
        var lowered_variant = std.json.ObjectMap.empty;
        if (value) |item| try lowered_variant.put(allocator, "value", item);
        if (kind) |item| try lowered_variant.put(allocator, "kind", item);
        try lowered_variant.put(allocator, "rules", .{ .array = lowered_rules });
        try variants.append(.{ .object = lowered_variant });
    }
    try config.put(allocator, "variants", .{ .array = variants });
    return makeRule(
        allocator,
        "tagged-union",
        input,
        path,
        .{ .object = config },
    );
}

fn lowerEventLog(
    allocator: std.mem.Allocator,
    rules: *std.json.Array,
    raw: std.json.Value,
    budget: *ExpansionBudget,
) !void {
    const event_log = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(event_log, &.{
        "start",
        "genesis",
        "kinds",
    });
    try definition_core.json.requireFields(event_log, &.{
        "start",
        "genesis",
        "kinds",
    });
    var sequence = std.json.ObjectMap.empty;
    try sequence.put(
        allocator,
        "start",
        try definition_core.json.field(event_log, "start"),
    );
    try appendRule(
        budget,
        rules,
        try makeRule(
            allocator,
            "sequence",
            null,
            null,
            .{ .object = sequence },
        ),
    );
    var previous_digest = std.json.ObjectMap.empty;
    try previous_digest.put(
        allocator,
        "genesis",
        try definition_core.json.field(event_log, "genesis"),
    );
    try appendRule(
        budget,
        rules,
        try makeRule(
            allocator,
            "previous-digest",
            null,
            null,
            .{ .object = previous_digest },
        ),
    );
    try appendRule(
        budget,
        rules,
        try makeRule(allocator, "body-digest", null, null, null),
    );
    try appendRule(
        budget,
        rules,
        try makeRule(allocator, "event-digest", null, null, null),
    );
    var kinds = std.json.ObjectMap.empty;
    try kinds.put(
        allocator,
        "values",
        try definition_core.json.field(event_log, "kinds"),
    );
    try appendRule(
        budget,
        rules,
        try makeRule(
            allocator,
            "event-kinds",
            null,
            null,
            .{ .object = kinds },
        ),
    );
}

fn lowerState(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    terms: ?std.json.ObjectMap,
    budget: *ExpansionBudget,
) !std.json.Value {
    const state = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(state, &.{
        "mode",
        "event_kind",
        "registers",
        "sets",
        "admissions",
    });
    try definition_core.json.requireFields(state, &.{
        "mode",
        "event_kind",
        "registers",
        "sets",
        "admissions",
    });
    var reducer = std.json.ObjectMap.empty;
    try reducer.put(
        allocator,
        "mode",
        try definition_core.json.field(state, "mode"),
    );
    try reducer.put(
        allocator,
        "event_kind",
        try definition_core.json.field(state, "event_kind"),
    );
    var registers = std.json.Array.init(allocator);
    var register_iterator = (try definition_core.json.object(
        try definition_core.json.field(state, "registers"),
    )).iterator();
    while (register_iterator.next()) |entry| {
        var register = std.json.ObjectMap.empty;
        try register.put(
            allocator,
            "name",
            .{ .string = entry.key_ptr.* },
        );
        try register.put(allocator, "max_bytes", entry.value_ptr.*);
        try registers.append(.{ .object = register });
    }
    try reducer.put(allocator, "registers", .{ .array = registers });

    var sets = std.json.Array.init(allocator);
    var set_iterator = (try definition_core.json.object(
        try definition_core.json.field(state, "sets"),
    )).iterator();
    while (set_iterator.next()) |entry| {
        const limits = try definition_core.json.array(entry.value_ptr.*);
        if (limits.items.len != 3) return error.InvalidStateSetLimits;
        var set = std.json.ObjectMap.empty;
        try set.put(allocator, "name", .{ .string = entry.key_ptr.* });
        try set.put(allocator, "max_entries", limits.items[0]);
        try set.put(allocator, "max_key_bytes", limits.items[1]);
        try set.put(allocator, "max_bytes", limits.items[2]);
        try sets.append(.{ .object = set });
    }
    try reducer.put(allocator, "sets", .{ .array = sets });

    const raw_admissions = try definition_core.json.array(
        try definition_core.json.field(state, "admissions"),
    );
    var admissions = std.json.Array.init(allocator);
    for (raw_admissions.items) |raw_admission| {
        const admission = try definition_core.json.object(raw_admission);
        try definition_core.json.requireExactKeys(admission, &.{
            "on",
            "requires",
            "forbids",
            "laws",
            "actions",
        });
        try definition_core.json.requireFields(admission, &.{"on"});
        var lowered = std.json.ObjectMap.empty;
        try lowered.put(
            allocator,
            "on",
            try definition_core.json.field(admission, "on"),
        );
        try lowered.put(
            allocator,
            "requires",
            admission.get("requires") orelse
                .{ .array = std.json.Array.init(allocator) },
        );
        try lowered.put(
            allocator,
            "forbids",
            admission.get("forbids") orelse
                .{ .array = std.json.Array.init(allocator) },
        );
        const admission_laws = if (admission.get("laws")) |laws|
            try lowerExpressions(
                allocator,
                try definition_core.json.array(laws),
                null,
                null,
                terms,
                true,
                budget,
            )
        else
            std.json.Array.init(allocator);
        try lowered.put(allocator, "rules", .{ .array = admission_laws });
        const admission_actions = if (admission.get("actions")) |actions|
            try lowerStateActions(
                allocator,
                try definition_core.json.array(actions),
            )
        else
            std.json.Array.init(allocator);
        try lowered.put(allocator, "actions", .{
            .array = admission_actions,
        });
        try admissions.append(.{ .object = lowered });
    }
    try reducer.put(allocator, "admissions", .{ .array = admissions });
    return makeRule(
        allocator,
        "reducer",
        null,
        null,
        .{ .object = reducer },
    );
}

fn lowerStateActions(
    allocator: std.mem.Allocator,
    raw: std.json.Array,
) !std.json.Array {
    var actions = std.json.Array.init(allocator);
    for (raw.items) |raw_action| {
        const action = try definition_core.json.array(raw_action);
        if (action.items.len < 2 or action.items.len > 4) {
            return error.InvalidStateAction;
        }
        const operator = try definition_core.json.string(action.items[0]);
        if (std.mem.eql(u8, operator, "clear")) {
            if (action.items.len != 2) return error.InvalidStateAction;
        } else if ((action.items.len != 3 and action.items.len != 4) or
            (!std.mem.eql(u8, operator, "set") and
                !std.mem.eql(u8, operator, "insert") and
                !std.mem.eql(u8, operator, "upsert")))
        {
            return error.InvalidStateAction;
        }
        var lowered = std.json.ObjectMap.empty;
        try lowered.put(allocator, "op", .{ .string = operator });
        const target_key = if (std.mem.eql(u8, operator, "insert"))
            "set"
        else
            "register";
        try lowered.put(allocator, target_key, action.items[1]);
        if (action.items.len == 3) {
            const source = try compactReference(action.items[2]);
            try putIfPresent(allocator, &lowered, "input", source.input);
            try lowered.put(
                allocator,
                "path",
                .{ .string = source.path },
            );
        }
        if (action.items.len == 4) {
            const source = try compactReference(action.items[2]);
            try putIfPresent(allocator, &lowered, "input", source.input);
            try lowered.put(
                allocator,
                "path",
                .{ .string = source.path },
            );
            const options = try definition_core.json.object(action.items[3]);
            var iterator = options.iterator();
            while (iterator.next()) |entry| {
                try putNonOverriding(
                    allocator,
                    &lowered,
                    entry.key_ptr.*,
                    entry.value_ptr.*,
                );
            }
        }
        try actions.append(.{ .object = lowered });
    }
    return actions;
}

fn lowerEventOperations(
    allocator: std.mem.Allocator,
    event: std.json.ObjectMap,
    plans: std.json.ObjectMap,
    budget: *ExpansionBudget,
) !std.json.ObjectMap {
    try definition_core.json.requireExactKeys(event, &.{
        "slot",
        "effect",
        "input",
        "mode",
        "body_input",
        "request",
        "forbid",
        "fields",
    });
    try definition_core.json.requireFields(event, &.{
        "slot",
        "effect",
        "input",
        "mode",
        "body_input",
        "fields",
    });
    var lowered_plans = std.json.ObjectMap.empty;
    var iterator = plans.iterator();
    while (iterator.next()) |entry| {
        try budget.reserve(1);
        const kind = switch (entry.value_ptr.*) {
            .string => |value| value,
            .object => |plan| try definition_core.json.requiredString(
                plan,
                "kind",
            ),
            else => return error.InvalidEventOperationPlan,
        };
        const plan = switch (entry.value_ptr.*) {
            .string => std.json.ObjectMap.empty,
            .object => |value| value,
            else => unreachable,
        };
        try definition_core.json.requireExactKeys(plan, &.{
            "effect",
            "input",
            "kind",
            "request",
            "generate",
            "body",
            "forbid",
            "fields",
        });
        var raw_effect = std.json.ObjectMap.empty;
        try raw_effect.put(
            allocator,
            "op",
            plan.get("effect") orelse
                try definition_core.json.field(event, "effect"),
        );
        try raw_effect.put(
            allocator,
            "slot",
            try definition_core.json.field(event, "slot"),
        );
        try raw_effect.put(
            allocator,
            "input",
            plan.get("input") orelse
                try definition_core.json.field(event, "input"),
        );
        var event_plan = std.json.ObjectMap.empty;
        try event_plan.put(
            allocator,
            "mode",
            try definition_core.json.field(event, "mode"),
        );
        try event_plan.put(
            allocator,
            "body_input_field",
            try definition_core.json.field(event, "body_input"),
        );
        try event_plan.put(allocator, "fields", .{
            .array = try lowerEventFields(
                allocator,
                try definition_core.json.object(
                    try definition_core.json.field(event, "fields"),
                ),
                if (plan.get("fields")) |fields|
                    try definition_core.json.object(fields)
                else
                    null,
                kind,
                budget,
            ),
        });
        const request_source = if (plan.get("request")) |request|
            request
        else
            event.get("request") orelse .null;
        if (request_source != .null) {
            try event_plan.put(allocator, "request_literals", .{
                .array = try lowerLiteralFields(
                    allocator,
                    try definition_core.json.object(request_source),
                    kind,
                    budget,
                ),
            });
        }
        if (plan.get("generate")) |generate| {
            try event_plan.put(allocator, "generate", .{
                .array = try lowerGeneratedFields(
                    allocator,
                    try definition_core.json.object(generate),
                    budget,
                ),
            });
        }
        if (plan.get("body")) |body| {
            try event_plan.put(allocator, "body_fields", .{
                .array = try lowerConfiguredFields(
                    allocator,
                    try definition_core.json.object(body),
                    budget,
                ),
            });
        }
        const forbidden = plan.get("forbid") orelse
            event.get("forbid") orelse .null;
        if (forbidden != .null) {
            const values = try definition_core.json.array(forbidden);
            if (values.items.len != 0) {
                try event_plan.put(
                    allocator,
                    "forbidden_parameters",
                    forbidden,
                );
            }
        }
        try raw_effect.put(
            allocator,
            "event",
            .{ .object = event_plan },
        );
        var effects = std.json.Array.init(allocator);
        try effects.append(.{ .object = raw_effect });
        var operation = std.json.ObjectMap.empty;
        try operation.put(allocator, "effects", .{ .array = effects });
        try lowered_plans.put(
            allocator,
            entry.key_ptr.*,
            .{ .object = operation },
        );
    }
    return lowered_plans;
}

fn lowerEventFields(
    allocator: std.mem.Allocator,
    fields: std.json.ObjectMap,
    overrides: ?std.json.ObjectMap,
    kind: []const u8,
    budget: *ExpansionBudget,
) !std.json.Array {
    var lowered = std.json.Array.init(allocator);
    var iterator = fields.iterator();
    while (iterator.next()) |entry| {
        try budget.reserve(1);
        const descriptor = if (overrides) |map|
            map.get(entry.key_ptr.*) orelse entry.value_ptr.*
        else
            entry.value_ptr.*;
        try lowered.append(.{
            .object = try lowerEventField(
                allocator,
                entry.key_ptr.*,
                descriptor,
                kind,
            ),
        });
    }
    if (overrides) |map| {
        var override_iterator = map.iterator();
        while (override_iterator.next()) |entry| {
            if (fields.contains(entry.key_ptr.*)) continue;
            try budget.reserve(1);
            try lowered.append(.{
                .object = try lowerEventField(
                    allocator,
                    entry.key_ptr.*,
                    entry.value_ptr.*,
                    kind,
                ),
            });
        }
    }
    return lowered;
}

fn lowerEventField(
    allocator: std.mem.Allocator,
    name: []const u8,
    raw: std.json.Value,
    kind: []const u8,
) !std.json.ObjectMap {
    var field = std.json.ObjectMap.empty;
    try field.put(allocator, "field", .{ .string = name });
    if (raw == .string) {
        if (std.mem.eql(u8, raw.string, "input")) {
            try field.put(allocator, "input_field", .{ .string = name });
            return field;
        }
        if (std.mem.eql(u8, raw.string, "unix-seconds")) {
            try field.put(allocator, "unix_seconds", .{ .bool = true });
            return field;
        }
        return error.InvalidEventField;
    }
    const descriptor = try definition_core.json.array(raw);
    if (descriptor.items.len != 2) return error.InvalidEventField;
    const operation = try definition_core.json.string(descriptor.items[0]);
    if (std.mem.eql(u8, operation, "input")) {
        try field.put(allocator, "input_field", descriptor.items[1]);
    } else if (std.mem.eql(u8, operation, "literal")) {
        const literal = if (descriptor.items[1] == .string and
            std.mem.eql(u8, descriptor.items[1].string, "$kind"))
            std.json.Value{ .string = kind }
        else
            descriptor.items[1];
        try field.put(allocator, "literal", literal);
    } else if (std.mem.eql(u8, operation, "sequence")) {
        try field.put(
            allocator,
            "sequence_text_prefix",
            descriptor.items[1],
        );
    } else {
        return error.InvalidEventField;
    }
    return field;
}

fn lowerLiteralFields(
    allocator: std.mem.Allocator,
    fields: std.json.ObjectMap,
    kind: []const u8,
    budget: *ExpansionBudget,
) !std.json.Array {
    var lowered = std.json.Array.init(allocator);
    var iterator = fields.iterator();
    while (iterator.next()) |entry| {
        try budget.reserve(1);
        var field = std.json.ObjectMap.empty;
        try field.put(
            allocator,
            "field",
            .{ .string = entry.key_ptr.* },
        );
        const literal = if (entry.value_ptr.* == .string and
            std.mem.eql(u8, entry.value_ptr.string, "$kind"))
            std.json.Value{ .string = kind }
        else
            entry.value_ptr.*;
        try field.put(allocator, "literal", literal);
        try lowered.append(.{ .object = field });
    }
    return lowered;
}

fn lowerGeneratedFields(
    allocator: std.mem.Allocator,
    fields: std.json.ObjectMap,
    budget: *ExpansionBudget,
) !std.json.Array {
    var lowered = std.json.Array.init(allocator);
    var iterator = fields.iterator();
    while (iterator.next()) |entry| {
        try budget.reserve(1);
        const descriptor = try definition_core.json.array(entry.value_ptr.*);
        if (descriptor.items.len != 3) {
            return error.InvalidGeneratedField;
        }
        var field = std.json.ObjectMap.empty;
        try field.put(
            allocator,
            "name",
            .{ .string = entry.key_ptr.* },
        );
        try field.put(allocator, "op", descriptor.items[0]);
        try field.put(allocator, "prefix", descriptor.items[1]);
        try field.put(allocator, "bytes", descriptor.items[2]);
        try lowered.append(.{ .object = field });
    }
    return lowered;
}

fn lowerConfiguredFields(
    allocator: std.mem.Allocator,
    fields: std.json.ObjectMap,
    budget: *ExpansionBudget,
) !std.json.Array {
    var lowered = std.json.Array.init(allocator);
    var iterator = fields.iterator();
    while (iterator.next()) |entry| {
        try budget.reserve(1);
        const config = try definition_core.json.object(entry.value_ptr.*);
        var field = std.json.ObjectMap.empty;
        try field.put(
            allocator,
            "field",
            .{ .string = entry.key_ptr.* },
        );
        var config_iterator = config.iterator();
        while (config_iterator.next()) |config_entry| {
            try putNonOverriding(
                allocator,
                &field,
                config_entry.key_ptr.*,
                config_entry.value_ptr.*,
            );
        }
        try lowered.append(.{ .object = field });
    }
    return lowered;
}

fn lowerExpressions(
    allocator: std.mem.Allocator,
    raw: std.json.Array,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) anyerror!std.json.Array {
    var lowered = std.json.Array.init(allocator);
    for (raw.items) |expression| {
        try appendRule(
            budget,
            &lowered,
            try lowerExpression(
                allocator,
                expression,
                inherited_input,
                inherited_path,
                terms,
                allow_terms,
                budget,
            ),
        );
    }
    return lowered;
}

fn lowerExpression(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) anyerror!std.json.Value {
    const expression = try definition_core.json.array(raw);
    if (expression.items.len == 0) return error.InvalidLawExpression;
    const operator = try definition_core.json.string(expression.items[0]);
    if (std.mem.eql(u8, operator, "use")) {
        if (!allow_terms or expression.items.len != 2) {
            return error.InvalidLawTerm;
        }
        const name = try definition_core.json.string(expression.items[1]);
        const term_map = terms orelse return error.UnknownLawTerm;
        const term = term_map.get(name) orelse return error.UnknownLawTerm;
        return lowerExpression(
            allocator,
            term,
            inherited_input,
            inherited_path,
            terms,
            false,
            budget,
        );
    }
    if (expression.items.len > 2) {
        return lowerPositionalExpression(
            allocator,
            expression,
            inherited_input,
            inherited_path,
            terms,
            allow_terms,
            budget,
        );
    }
    var result = std.json.ObjectMap.empty;
    try result.put(allocator, "op", .{ .string = operator });
    if (expression.items.len == 2) {
        const config = try definition_core.json.object(expression.items[1]);
        var iterator = config.iterator();
        while (iterator.next()) |entry| {
            try putNonOverriding(
                allocator,
                &result,
                entry.key_ptr.*,
                try lowerNestedExpressions(
                    allocator,
                    entry.key_ptr.*,
                    entry.value_ptr.*,
                    terms,
                    allow_terms,
                    budget,
                ),
            );
        }
    }
    if (inherited_input) |input| {
        if (!result.contains("input")) {
            try result.put(allocator, "input", .{ .string = input });
        }
    }
    if (inherited_path) |path| {
        if (path.len != 0 and !result.contains("path")) {
            try result.put(allocator, "path", .{ .string = path });
        }
    }
    return .{ .object = result };
}

fn lowerNestedExpressions(
    allocator: std.mem.Allocator,
    key: []const u8,
    raw: std.json.Value,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) anyerror!std.json.Value {
    if (std.mem.eql(u8, key, "rules") or
        std.mem.eql(u8, key, "target_rules") or
        std.mem.eql(u8, key, "coverage_rules") or
        std.mem.eql(u8, key, "match_rules"))
    {
        return .{
            .array = try lowerNestedRuleList(
                allocator,
                try definition_core.json.array(raw),
                terms,
                allow_terms,
                budget,
            ),
        };
    }
    return switch (raw) {
        .object => |object| result: {
            var clone = std.json.ObjectMap.empty;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try clone.put(
                    allocator,
                    entry.key_ptr.*,
                    try lowerNestedExpressions(
                        allocator,
                        entry.key_ptr.*,
                        entry.value_ptr.*,
                        terms,
                        allow_terms,
                        budget,
                    ),
                );
            }
            break :result .{ .object = clone };
        },
        .array => |array| result: {
            var clone = std.json.Array.init(allocator);
            for (array.items) |item| {
                try clone.append(try lowerNestedExpressions(
                    allocator,
                    "",
                    item,
                    terms,
                    allow_terms,
                    budget,
                ));
            }
            break :result .{ .array = clone };
        },
        else => raw,
    };
}

fn lowerNestedRuleList(
    allocator: std.mem.Allocator,
    raw: std.json.Array,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) anyerror!std.json.Array {
    var lowered = std.json.Array.init(allocator);
    for (raw.items) |rule| {
        try appendRule(
            budget,
            &lowered,
            if (rule == .array)
                try lowerExpression(
                    allocator,
                    rule,
                    null,
                    null,
                    terms,
                    allow_terms,
                    budget,
                )
            else
                try lowerNestedExpressions(
                    allocator,
                    "",
                    rule,
                    terms,
                    allow_terms,
                    budget,
                ),
        );
    }
    return lowered;
}

const CompactReference = struct {
    input: ?[]const u8,
    path: []const u8,
};

fn compactReference(raw: std.json.Value) !CompactReference {
    const text = try definition_core.json.string(raw);
    const separator = std.mem.indexOfScalar(u8, text, '#') orelse
        return error.InvalidCompactReference;
    if (std.mem.indexOfScalarPos(u8, text, separator + 1, '#') != null) {
        return error.InvalidCompactReference;
    }
    const input = text[0..separator];
    const path = text[separator + 1 ..];
    if (input.len != 0) try definition_core.json.safeIdentifier(input, 128);
    if (path.len != 0 and path[0] != '/') {
        return error.InvalidCompactReference;
    }
    return .{
        .input = if (input.len == 0) null else input,
        .path = path,
    };
}

fn resolvedInput(
    reference: CompactReference,
    inherited: ?[]const u8,
) ?[]const u8 {
    return reference.input orelse inherited;
}

fn resolvedPath(
    allocator: std.mem.Allocator,
    reference: CompactReference,
    inherited: ?[]const u8,
) ![]const u8 {
    if (reference.input != null or inherited == null or inherited.?.len == 0) {
        return reference.path;
    }
    if (reference.path.len == 0) return inherited.?;
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ inherited.?, reference.path },
    );
}

fn putIfPresent(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    name: []const u8,
    value: ?[]const u8,
) !void {
    if (value) |text| {
        try object.put(allocator, name, .{ .string = text });
    }
}

fn lowerPositionalExpression(
    allocator: std.mem.Allocator,
    expression: std.json.Array,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) anyerror!std.json.Value {
    const operator = try definition_core.json.string(expression.items[0]);
    if (isBinaryReferenceOperator(operator)) {
        if (expression.items.len != 3) return error.InvalidLawExpression;
        const left = try compactReference(expression.items[1]);
        const right = try compactReference(expression.items[2]);
        const left_input = resolvedInput(left, inherited_input) orelse
            return error.InvalidCompactReference;
        const right_input = resolvedInput(right, inherited_input) orelse
            return error.InvalidCompactReference;
        var result = std.json.ObjectMap.empty;
        try result.put(allocator, "op", .{ .string = operator });
        try result.put(allocator, "input", .{ .string = left_input });
        if (!std.mem.eql(u8, operator, "field-equal") or
            !std.mem.eql(u8, left_input, right_input))
        {
            try result.put(allocator, "left_input", .{ .string = left_input });
            try result.put(allocator, "right_input", .{ .string = right_input });
        }
        try result.put(allocator, "left", .{
            .string = try resolvedPath(
                allocator,
                left,
                inherited_path,
            ),
        });
        try result.put(allocator, "right", .{
            .string = try resolvedPath(
                allocator,
                right,
                inherited_path,
            ),
        });
        return .{ .object = result };
    }
    if (std.mem.eql(u8, operator, "definition-ref")) {
        if (expression.items.len != 3) return error.InvalidLawExpression;
        const subject = try compactReference(expression.items[1]);
        var result = std.json.ObjectMap.empty;
        try result.put(allocator, "op", .{ .string = operator });
        try putIfPresent(
            allocator,
            &result,
            "input",
            resolvedInput(subject, inherited_input),
        );
        try result.put(allocator, "path", .{
            .string = try resolvedPath(
                allocator,
                subject,
                inherited_path,
            ),
        });
        try result.put(allocator, "definition", expression.items[2]);
        return .{ .object = result };
    }
    if (std.mem.eql(u8, operator, "bounded-array") or
        std.mem.eql(u8, operator, "bounded-number"))
    {
        if (expression.items.len != 4) return error.InvalidLawExpression;
        const subject = try compactReference(expression.items[1]);
        var result = std.json.ObjectMap.empty;
        try result.put(allocator, "op", .{ .string = operator });
        try putIfPresent(
            allocator,
            &result,
            "input",
            resolvedInput(subject, inherited_input),
        );
        try result.put(allocator, "path", .{
            .string = try resolvedPath(
                allocator,
                subject,
                inherited_path,
            ),
        });
        if (expression.items[2] != .null) {
            try result.put(allocator, "min", expression.items[2]);
        }
        if (expression.items[3] != .null) {
            try result.put(allocator, "max", expression.items[3]);
        }
        return .{ .object = result };
    }
    if (std.mem.eql(u8, operator, "enum")) {
        if (expression.items.len != 3) return error.InvalidLawExpression;
        const subject = try compactReference(expression.items[1]);
        var result = std.json.ObjectMap.empty;
        try result.put(allocator, "op", .{ .string = operator });
        try putIfPresent(
            allocator,
            &result,
            "input",
            resolvedInput(subject, inherited_input),
        );
        try result.put(allocator, "path", .{
            .string = try resolvedPath(
                allocator,
                subject,
                inherited_path,
            ),
        });
        try result.put(allocator, "values", expression.items[2]);
        return .{ .object = result };
    }
    if (std.mem.eql(u8, operator, "all") or
        std.mem.eql(u8, operator, "any") or
        std.mem.eql(u8, operator, "none"))
    {
        if (expression.items.len != 3) return error.InvalidLawExpression;
        const subject = try compactReference(expression.items[1]);
        var result = std.json.ObjectMap.empty;
        try result.put(allocator, "op", .{ .string = operator });
        try putIfPresent(
            allocator,
            &result,
            "input",
            resolvedInput(subject, inherited_input),
        );
        try result.put(allocator, "path", .{
            .string = try resolvedPath(
                allocator,
                subject,
                inherited_path,
            ),
        });
        try result.put(allocator, "rules", .{
            .array = try lowerExpressions(
                allocator,
                try definition_core.json.array(expression.items[2]),
                null,
                null,
                terms,
                allow_terms,
                budget,
            ),
        });
        return .{ .object = result };
    }
    if (std.mem.eql(u8, operator, "implies")) {
        return lowerCompactImplication(
            allocator,
            expression,
            inherited_input,
            inherited_path,
            terms,
            allow_terms,
            budget,
        );
    }
    if (std.mem.eql(u8, operator, "reference-exists")) {
        return lowerCompactRelation(
            allocator,
            expression,
            inherited_input,
            inherited_path,
            terms,
            allow_terms,
            budget,
        );
    }
    return error.UnsupportedPositionalLaw;
}

fn isBinaryReferenceOperator(operator: []const u8) bool {
    inline for (.{
        "field-equal",
        "field-not-equal",
        "cross-input-equal",
        "set-equality",
        "subset",
        "member-of",
        "not-member-of",
        "path-scope-subset",
        "path-scope-disjoint",
    }) |candidate| {
        if (std.mem.eql(u8, operator, candidate)) return true;
    }
    return false;
}

fn lowerCompactImplication(
    allocator: std.mem.Allocator,
    expression: std.json.Array,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) anyerror!std.json.Value {
    if (expression.items.len != 4) return error.InvalidLawExpression;
    const condition = try compactReference(expression.items[1]);
    const predicate = try definition_core.json.object(expression.items[2]);
    try definition_core.json.requireExactKeys(predicate, &.{
        "equals",
        "not_equals",
        "empty",
        "nonempty",
    });
    const condition_input = resolvedInput(condition, inherited_input) orelse
        return error.InvalidCompactReference;
    var result = std.json.ObjectMap.empty;
    try result.put(allocator, "op", .{ .string = "implies" });
    try result.put(allocator, "input", .{ .string = condition_input });
    try result.put(allocator, "if", .{
        .string = try resolvedPath(
            allocator,
            condition,
            inherited_path,
        ),
    });
    var predicate_iterator = predicate.iterator();
    while (predicate_iterator.next()) |entry| {
        try result.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
    switch (expression.items[3]) {
        .array => |rules| try result.put(allocator, "rules", .{
            .array = try lowerExpressions(
                allocator,
                rules,
                null,
                null,
                terms,
                allow_terms,
                budget,
            ),
        }),
        .object => |consequence| {
            try definition_core.json.requireExactKeys(consequence, &.{
                "then",
                "equals",
                "nonempty",
            });
            const then = try compactReference(
                try definition_core.json.field(consequence, "then"),
            );
            try putIfPresent(
                allocator,
                &result,
                "then_input",
                resolvedInput(then, inherited_input),
            );
            try result.put(allocator, "then", .{
                .string = try resolvedPath(
                    allocator,
                    then,
                    inherited_path,
                ),
            });
            if (consequence.get("equals")) |value| {
                try result.put(allocator, "then_equals", value);
            }
            if (consequence.get("nonempty")) |value| {
                try result.put(allocator, "then_nonempty", value);
            }
        },
        else => return error.InvalidLawExpression,
    }
    return .{ .object = result };
}

fn lowerCompactRelation(
    allocator: std.mem.Allocator,
    expression: std.json.Array,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) anyerror!std.json.Value {
    if (expression.items.len < 3 or expression.items.len > 4) {
        return error.InvalidLawExpression;
    }
    const raw_sources = try definition_core.json.array(expression.items[1]);
    const raw_targets = try definition_core.json.array(expression.items[2]);
    if (raw_sources.items.len == 0 or raw_targets.items.len == 0) {
        return error.InvalidCompactRelation;
    }
    var result = std.json.ObjectMap.empty;
    try result.put(allocator, "op", .{ .string = "reference-exists" });
    var sources = std.json.Array.init(allocator);
    var source_input: ?[]const u8 = null;
    for (raw_sources.items) |raw_endpoint| {
        const endpoint = try lowerCompactEndpoint(
            allocator,
            raw_endpoint,
            "reference",
            inherited_path,
            terms,
            allow_terms,
            budget,
        );
        const input = resolvedInput(endpoint.reference, inherited_input) orelse
            return error.InvalidCompactReference;
        if (source_input) |expected| {
            if (!std.mem.eql(u8, expected, input)) {
                return error.MixedRelationSourceInputs;
            }
        } else source_input = input;
        try sources.append(.{ .object = endpoint.object });
    }
    var targets = std.json.Array.init(allocator);
    var target_input: ?[]const u8 = null;
    for (raw_targets.items) |raw_endpoint| {
        const endpoint = try lowerCompactEndpoint(
            allocator,
            raw_endpoint,
            "key",
            inherited_path,
            terms,
            allow_terms,
            budget,
        );
        const input = resolvedInput(endpoint.reference, inherited_input) orelse
            return error.InvalidCompactReference;
        if (target_input) |expected| {
            if (!std.mem.eql(u8, expected, input)) {
                return error.MixedRelationTargetInputs;
            }
        } else target_input = input;
        try targets.append(.{ .object = endpoint.object });
    }
    try result.put(allocator, "input", .{ .string = source_input.? });
    if (!std.mem.eql(u8, source_input.?, target_input.?)) {
        try result.put(allocator, "target_input", .{ .string = target_input.? });
    }
    var single = false;
    if (expression.items.len == 4) {
        const options = try definition_core.json.object(expression.items[3]);
        var iterator = options.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "single")) {
                single = try definition_core.json.boolean(entry.value_ptr.*);
                continue;
            }
            try putNonOverridingReserved(
                allocator,
                &result,
                entry.key_ptr.*,
                try lowerNestedExpressions(
                    allocator,
                    entry.key_ptr.*,
                    entry.value_ptr.*,
                    terms,
                    allow_terms,
                    budget,
                ),
                &.{
                    "path",
                    "reference",
                    "target",
                    "target_input",
                    "key",
                    "sources",
                    "targets",
                },
            );
        }
    }
    if (single) {
        if (sources.items.len != 1 or targets.items.len != 1) {
            return error.InvalidCompactRelation;
        }
        const source = try definition_core.json.object(sources.items[0]);
        const target = try definition_core.json.object(targets.items[0]);
        try definition_core.json.requireExactKeys(
            source,
            &.{ "path", "reference" },
        );
        try definition_core.json.requireExactKeys(
            target,
            &.{ "path", "items", "key", "rules", "coverage_rules" },
        );
        try result.put(
            allocator,
            "path",
            try definition_core.json.field(source, "path"),
        );
        try result.put(
            allocator,
            "reference",
            try definition_core.json.field(source, "reference"),
        );
        try result.put(
            allocator,
            "target",
            try definition_core.json.field(target, "path"),
        );
        try result.put(
            allocator,
            "key",
            try definition_core.json.field(target, "key"),
        );
        if (target.get("items")) |items| {
            try result.put(allocator, "target_items", items);
        }
        if (target.get("rules")) |rules| {
            try result.put(allocator, "target_rules", rules);
        }
        if (target.get("coverage_rules")) |rules| {
            try result.put(allocator, "coverage_rules", rules);
        }
    } else {
        try result.put(allocator, "sources", .{ .array = sources });
        try result.put(allocator, "targets", .{ .array = targets });
    }
    return .{ .object = result };
}

const CompactEndpoint = struct {
    reference: CompactReference,
    object: std.json.ObjectMap,
};

fn lowerCompactEndpoint(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    selector_key: []const u8,
    inherited_path: ?[]const u8,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) anyerror!CompactEndpoint {
    const endpoint = try definition_core.json.array(raw);
    if (endpoint.items.len < 2 or endpoint.items.len > 3) {
        return error.InvalidCompactRelationEndpoint;
    }
    const reference = try compactReference(endpoint.items[0]);
    var object = std.json.ObjectMap.empty;
    try object.put(allocator, "path", .{
        .string = try resolvedPath(
            allocator,
            reference,
            inherited_path,
        ),
    });
    if (endpoint.items[1] != .null) {
        try object.put(allocator, selector_key, endpoint.items[1]);
    }
    if (endpoint.items.len == 3) {
        const options = try definition_core.json.object(endpoint.items[2]);
        var iterator = options.iterator();
        while (iterator.next()) |entry| {
            try putNonOverriding(
                allocator,
                &object,
                entry.key_ptr.*,
                try lowerNestedExpressions(
                    allocator,
                    entry.key_ptr.*,
                    entry.value_ptr.*,
                    terms,
                    allow_terms,
                    budget,
                ),
            );
        }
    }
    return .{ .reference = reference, .object = object };
}

fn makeRule(
    allocator: std.mem.Allocator,
    operator: []const u8,
    input: ?[]const u8,
    path: ?[]const u8,
    config: ?std.json.Value,
) !std.json.Value {
    var object = std.json.ObjectMap.empty;
    try object.put(allocator, "op", .{ .string = operator });
    if (input) |value| try object.put(allocator, "input", .{ .string = value });
    if (path) |value| try object.put(allocator, "path", .{ .string = value });
    if (config) |raw_config| {
        const config_object = try definition_core.json.object(raw_config);
        var iterator = config_object.iterator();
        while (iterator.next()) |entry| {
            try putNonOverriding(
                allocator,
                &object,
                entry.key_ptr.*,
                entry.value_ptr.*,
            );
        }
    }
    return .{ .object = object };
}

fn appendRule(
    budget: *ExpansionBudget,
    rules: *std.json.Array,
    rule: std.json.Value,
) !void {
    try budget.reserve(1);
    try rules.append(rule);
}

fn containsString(
    values: []const []const u8,
    candidate: []const u8,
) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn collectDocumentTypeUses(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    used: *std.json.ObjectMap,
    depth: usize,
) anyerror!void {
    if (depth > 64) return error.ArtifactRuleDepthExceeded;
    if (raw == .array) {
        const reference = try definition_core.json.array(raw);
        if (reference.items.len == 2 and
            reference.items[0] == .string and
            std.mem.eql(u8, reference.items[0].string, "use"))
        {
            const name = try definition_core.json.string(reference.items[1]);
            try definition_core.json.safeIdentifier(name, 128);
            try used.put(allocator, name, .null);
        }
        return;
    }
    const node = try definition_core.json.object(raw);
    if (node.get("fields")) |raw_fields| {
        var iterator = (try definition_core.json.object(
            raw_fields,
        )).iterator();
        while (iterator.next()) |entry| {
            try collectDocumentTypeUses(
                allocator,
                entry.value_ptr.*,
                used,
                depth + 1,
            );
        }
    }
    inline for (.{ "items", "values" }) |name| {
        if (node.get(name)) |child| {
            try collectDocumentTypeUses(
                allocator,
                child,
                used,
                depth + 1,
            );
        }
    }
    if (node.get("one_of")) |raw_variants| {
        for ((try definition_core.json.array(raw_variants)).items) |variant| {
            try collectDocumentTypeUses(
                allocator,
                variant,
                used,
                depth + 1,
            );
        }
    }
    if (node.get("tagged")) |raw_tagged| {
        const tagged = try definition_core.json.object(raw_tagged);
        const variants = try definition_core.json.array(
            try definition_core.json.field(tagged, "variants"),
        );
        for (variants.items) |raw_variant| {
            const variant = try definition_core.json.object(raw_variant);
            try collectDocumentTypeUses(
                allocator,
                try definition_core.json.field(variant, "node"),
                used,
                depth + 1,
            );
        }
    }
}

fn requireUsedDeclarationNames(
    declarations: std.json.ObjectMap,
    used: std.json.ObjectMap,
    unused_error: anyerror,
) !void {
    var declaration_iterator = declarations.iterator();
    while (declaration_iterator.next()) |entry| {
        try definition_core.json.safeIdentifier(entry.key_ptr.*, 128);
        if (!used.contains(entry.key_ptr.*)) return unused_error;
    }
}

fn collectLawTermUses(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    used: *std.json.ObjectMap,
    depth: usize,
) anyerror!void {
    if (depth > 64) return error.ArtifactRuleDepthExceeded;
    const laws = try definition_core.json.array(raw);
    for (laws.items) |raw_expression| {
        const expression = try definition_core.json.array(raw_expression);
        if (expression.items.len == 0) continue;
        const operator = try definition_core.json.string(expression.items[0]);
        if (std.mem.eql(u8, operator, "use")) {
            if (expression.items.len != 2) continue;
            const name = try definition_core.json.string(expression.items[1]);
            try definition_core.json.safeIdentifier(name, 128);
            try used.put(allocator, name, .null);
            continue;
        }
        if ((std.mem.eql(u8, operator, "all") or
            std.mem.eql(u8, operator, "any") or
            std.mem.eql(u8, operator, "none")) and
            expression.items.len == 3)
        {
            try collectLawTermUses(
                allocator,
                expression.items[2],
                used,
                depth + 1,
            );
        }
        if (std.mem.eql(u8, operator, "implies") and
            expression.items.len == 4 and
            expression.items[3] == .array)
        {
            try collectLawTermUses(
                allocator,
                expression.items[3],
                used,
                depth + 1,
            );
        }
        for (expression.items[1..]) |item| {
            try collectNestedLawTermUses(
                allocator,
                item,
                used,
                depth + 1,
            );
        }
    }
}

fn collectNestedLawTermUses(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    used: *std.json.ObjectMap,
    depth: usize,
) anyerror!void {
    if (depth > 64) return error.ArtifactRuleDepthExceeded;
    switch (raw) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "rules") or
                    std.mem.eql(u8, entry.key_ptr.*, "target_rules") or
                    std.mem.eql(u8, entry.key_ptr.*, "coverage_rules") or
                    std.mem.eql(u8, entry.key_ptr.*, "match_rules"))
                {
                    try collectLawTermUses(
                        allocator,
                        entry.value_ptr.*,
                        used,
                        depth + 1,
                    );
                    continue;
                }
                try collectNestedLawTermUses(
                    allocator,
                    entry.value_ptr.*,
                    used,
                    depth + 1,
                );
            }
        },
        .array => |array| for (array.items) |item| {
            try collectNestedLawTermUses(
                allocator,
                item,
                used,
                depth + 1,
            );
        },
        else => {},
    }
}

fn putNonOverriding(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
) !void {
    return putNonOverridingReserved(allocator, object, key, value, &.{});
}

fn putNonOverridingReserved(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
    reserved: []const []const u8,
) !void {
    if (object.contains(key)) return error.SourceGraphFieldCollision;
    for (reserved) |name| {
        if (std.mem.eql(u8, key, name)) {
            return error.SourceGraphFieldCollision;
        }
    }
    try object.put(allocator, key, value);
}

fn boolAsEmptyObject(raw: std.json.Value) std.json.Value {
    if (raw == .bool and raw.bool) {
        return .{ .object = std.json.ObjectMap.empty };
    }
    return raw;
}

fn optionalBool(
    object: std.json.ObjectMap,
    key: []const u8,
    default: bool,
) !bool {
    const raw = object.get(key) orelse return default;
    if (raw != .bool) return error.ExpectedBoolean;
    return raw.bool;
}

const OptionalPresence = enum {
    required,
    optional,
    nullable,
};

fn optionalPresence(object: std.json.ObjectMap) !OptionalPresence {
    const raw = object.get("optional") orelse return .required;
    return switch (raw) {
        .bool => |value| if (value) .optional else .required,
        .string => |value| if (std.mem.eql(u8, value, "nullable"))
            .nullable
        else
            error.InvalidOptionalPresence,
        else => error.InvalidOptionalPresence,
    };
}

fn ifPresentPresence(object: std.json.ObjectMap) !OptionalPresence {
    const raw = object.get("if_present") orelse return .required;
    return switch (raw) {
        .bool => |value| if (value) .optional else .required,
        .string => |value| if (std.mem.eql(u8, value, "nullable"))
            .nullable
        else
            error.InvalidIfPresentMode,
        else => error.InvalidIfPresentMode,
    };
}

fn joinPointer(
    allocator: std.mem.Allocator,
    base: []const u8,
    field: []const u8,
) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    try result.appendSlice(allocator, base);
    try result.append(allocator, '/');
    for (field) |byte| switch (byte) {
        '~' => try result.appendSlice(allocator, "~0"),
        '/' => try result.appendSlice(allocator, "~1"),
        else => try result.append(allocator, byte),
    };
    return result.toOwnedSlice(allocator);
}

test "structural graph lowers to bounded native rules" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "documents": {
        \\    "record": {
        \\      "object": "closed",
        \\      "fields": {
        \\        "id": {"identifier": {"max": 32}},
        \\        "status": {"enum": ["open", "closed"]},
        \\        "note": {
        \\          "optional": "nullable",
        \\          "string": {"max": 128}
        \\        },
        \\        "required_note": {
        \\          "if_present": "nullable",
        \\          "string": {"max": 128}
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        source,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: ExpansionBudget = .{};
    const lowered = try lowerShape(
        arena.allocator(),
        parsed.value,
        &.{"record"},
        &budget,
    );
    const rules = try definition_core.json.array(lowered);
    try std.testing.expectEqual(@as(usize, 5), rules.items.len);
    const object = try definition_core.json.object(rules.items[0]);
    try std.testing.expectEqualStrings(
        "exact-object",
        try definition_core.json.requiredString(object, "op"),
    );
    const optional = try definition_core.json.array(
        try definition_core.json.field(object, "optional_keys"),
    );
    try std.testing.expectEqual(@as(usize, 1), optional.items.len);
    const required = try definition_core.json.array(
        try definition_core.json.field(object, "required_keys"),
    );
    try std.testing.expectEqual(@as(usize, 3), required.items.len);
    const note = try definition_core.json.object(rules.items[3]);
    try std.testing.expectEqualStrings(
        "optional-field",
        try definition_core.json.requiredString(note, "op"),
    );
    try std.testing.expect(
        (try definition_core.json.field(note, "allow_null")).bool,
    );
    const required_note = try definition_core.json.object(rules.items[4]);
    try std.testing.expectEqualStrings(
        "optional-field",
        try definition_core.json.requiredString(required_note, "op"),
    );
    try std.testing.expect(
        (try definition_core.json.field(required_note, "allow_null")).bool,
    );
}

test "structural graph rejects redirected and nested rules" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        expected: anyerror,
    }{
        .{
            .source =
            \\{"documents":{"record":{"fields":{"id":{"string":{"max":1,"path":"/name"}}}}}}
            ,
            .expected = error.SourceGraphFieldCollision,
        },
        .{
            .source =
            \\{"documents":{"record":{"fields":{"nested":{"event_envelope":{}}}}}}
            ,
            .expected = error.EventEnvelopeMustBeDocumentRoot,
        },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            case.source,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var budget: ExpansionBudget = .{};
        try std.testing.expectError(
            case.expected,
            lowerShape(
                arena.allocator(),
                parsed.value,
                &.{"record"},
                &budget,
            ),
        );
    }
}

test "structural graph binds node laws to their document and path" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"documents":{"a":{},"b":{"fields":{"value":{"laws":[["enum",{"values":["ok"]}]]}}}}}
    ,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: ExpansionBudget = .{};
    const lowered = try lowerShape(
        arena.allocator(),
        parsed.value,
        &.{ "a", "b" },
        &budget,
    );
    const rules = try definition_core.json.array(lowered);
    try std.testing.expectEqual(@as(usize, 1), rules.items.len);
    const rule = try definition_core.json.object(rules.items[0]);
    try std.testing.expectEqualStrings(
        "b",
        try definition_core.json.requiredString(rule, "input"),
    );
    try std.testing.expectEqualStrings(
        "/value",
        try definition_core.json.requiredString(rule, "path"),
    );
}

test "structural graph closes declarations and bounds expansion" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        expected: anyerror,
    }{
        .{
            .source =
            \\{"documents":{"ghost":{}}}
            ,
            .expected = error.UnknownDocumentInput,
        },
        .{
            .source =
            \\{"types":{"bad":{"unknown":true}},"documents":{"record":{}}}
            ,
            .expected = error.UnusedDocumentType,
        },
        .{
            .source =
            \\{"types":{"bad":{"unknown":true}},"documents":{"record":{"enum":["use","bad"]}}}
            ,
            .expected = error.UnusedDocumentType,
        },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            case.source,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var budget: ExpansionBudget = .{};
        try std.testing.expectError(
            case.expected,
            lowerShape(
                arena.allocator(),
                parsed.value,
                &.{"record"},
                &budget,
            ),
        );
    }

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"documents":{"record":{"scalar":"string"}}}
    ,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: ExpansionBudget = .{ .emitted = ExpansionBudget.max_emitted };
    try std.testing.expectError(
        error.SourceGraphExpansionLimitExceeded,
        lowerShape(
            arena.allocator(),
            parsed.value,
            &.{"record"},
            &budget,
        ),
    );
}

test "law expressions lower nested rules without executable hooks" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "laws": [
        \\    ["implies", {
        \\      "input": "record",
        \\      "if": "/status",
        \\      "equals": "closed",
        \\      "rules": [
        \\        ["bounded-string", {"path": "/note", "min": 1}]
        \\      ]
        \\    }]
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        source,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: ExpansionBudget = .{};
    const lowered = try lowerConstraints(
        arena.allocator(),
        parsed.value,
        &.{"record"},
        &budget,
    );
    const laws = try definition_core.json.array(lowered);
    const rule = try definition_core.json.object(laws.items[0]);
    try std.testing.expectEqualStrings(
        "implies",
        try definition_core.json.requiredString(rule, "op"),
    );
    const nested = try definition_core.json.array(
        try definition_core.json.field(rule, "rules"),
    );
    const nested_rule = try definition_core.json.object(nested.items[0]);
    try std.testing.expectEqualStrings(
        "bounded-string",
        try definition_core.json.requiredString(nested_rule, "op"),
    );
}

test "literal values do not satisfy law term closure" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"terms":{"bad":["not-native",{}]},"laws":[["enum",{"path":"","values":["use","bad"]}]]}
    ,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: ExpansionBudget = .{};
    try std.testing.expectError(
        error.UnusedLawTerm,
        lowerConstraints(
            arena.allocator(),
            parsed.value,
            &.{"record"},
            &budget,
        ),
    );
}

test "compact terms scope protocol and retained state lower once" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "terms": {
        \\    "same-id": [
        \\      "cross-input-equal",
        \\      "#/id",
        \\      "prior#/id"
        \\    ]
        \\  },
        \\  "scope": {
        \\    "input": "event",
        \\    "path": "/body"
        \\  },
        \\  "laws": [
        \\    ["use", "same-id"],
        \\    [
        \\      "reference-exists",
        \\      [["#/refs", ""]],
        \\      [["prior#/items", "/id"]],
        \\      {"single": true}
        \\    ]
        \\  ],
        \\  "event_log": {
        \\    "start": 1,
        \\    "genesis": null,
        \\    "kinds": ["created"]
        \\  },
        \\  "state": {
        \\    "mode": "retained",
        \\    "event_kind": "/kind",
        \\    "registers": {"current": 4096},
        \\    "sets": {},
        \\    "admissions": [{
        \\      "on": "created",
        \\      "forbids": ["current"],
        \\      "actions": [["set", "current", "event#/body"]]
        \\    }]
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        source,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: ExpansionBudget = .{};
    const lowered = try lowerConstraints(
        arena.allocator(),
        parsed.value,
        &.{ "event", "prior" },
        &budget,
    );
    const rules = try definition_core.json.array(lowered);
    try std.testing.expectEqual(@as(usize, 8), rules.items.len);

    const equality = try definition_core.json.object(rules.items[0]);
    try std.testing.expectEqualStrings(
        "/body/id",
        try definition_core.json.requiredString(equality, "left"),
    );
    try std.testing.expectEqualStrings(
        "/id",
        try definition_core.json.requiredString(equality, "right"),
    );
    const relation = try definition_core.json.object(rules.items[1]);
    try std.testing.expectEqualStrings(
        "/body/refs",
        try definition_core.json.requiredString(relation, "path"),
    );
    try std.testing.expectEqualStrings(
        "/items",
        try definition_core.json.requiredString(relation, "target"),
    );
    const reducer = try definition_core.json.object(rules.items[7]);
    try std.testing.expectEqualStrings(
        "reducer",
        try definition_core.json.requiredString(reducer, "op"),
    );
}

test "single compact relation preserves target rules" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"laws":[["reference-exists",[["record#/refs",""]],[["record#/items","/id",{"rules":[["enum",{"path":"/status","values":["active"]}]]}]],{"single":true}]]}
    ,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: ExpansionBudget = .{};
    const lowered = try lowerConstraints(
        arena.allocator(),
        parsed.value,
        &.{"record"},
        &budget,
    );
    const rules = try definition_core.json.array(lowered);
    const relation = try definition_core.json.object(rules.items[0]);
    const target_rules = try definition_core.json.array(
        try definition_core.json.field(relation, "target_rules"),
    );
    const target_rule = try definition_core.json.object(target_rules.items[0]);
    try std.testing.expectEqualStrings(
        "enum",
        try definition_core.json.requiredString(target_rule, "op"),
    );
}

test "compact relation options cannot redirect the declared target input" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"laws":[["reference-exists",[["a#/refs",""]],[["a#/items","/id"]],{"target_input":"b"}]]}
    ,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: ExpansionBudget = .{};
    try std.testing.expectError(
        error.SourceGraphFieldCollision,
        lowerConstraints(
            arena.allocator(),
            parsed.value,
            &.{ "a", "b" },
            &budget,
        ),
    );
}

test "shared event template lowers passive operation plans" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "$event": {
        \\    "slot": "events",
        \\    "effect": "compare-and-append",
        \\    "input": "request",
        \\    "mode": "chained",
        \\    "body_input": "body",
        \\    "request": {
        \\      "schema": "example-request/v1",
        \\      "kind": "$kind"
        \\    },
        \\    "forbid": ["capability"],
        \\    "fields": {
        \\      "event_id": ["sequence", "e-"],
        \\      "kind": ["literal", "$kind"],
        \\      "recorded_at": "unix-seconds"
        \\    }
        \\  },
        \\  "capture": "created",
        \\  "bind": {
        \\    "effect": "bind-existing",
        \\    "input": "existing",
        \\    "kind": "input",
        \\    "request": null,
        \\    "forbid": [],
        \\    "fields": {"kind": "input"}
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        source,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: ExpansionBudget = .{};
    const lowered = try lowerOperations(
        arena.allocator(),
        parsed.value,
        &budget,
    );
    const operations = try definition_core.json.object(lowered);
    try std.testing.expectEqual(@as(usize, 2), operations.count());
    const capture = try definition_core.json.object(
        try definition_core.json.field(operations, "capture"),
    );
    const effects = try definition_core.json.array(
        try definition_core.json.field(capture, "effects"),
    );
    const effect = try definition_core.json.object(effects.items[0]);
    try std.testing.expectEqualStrings(
        "compare-and-append",
        try definition_core.json.requiredString(effect, "op"),
    );
    const event = try definition_core.json.object(
        try definition_core.json.field(effect, "event"),
    );
    const request_literals = try definition_core.json.array(
        try definition_core.json.field(event, "request_literals"),
    );
    const kind = try definition_core.json.object(request_literals.items[1]);
    try std.testing.expectEqualStrings(
        "created",
        try definition_core.json.requiredString(kind, "literal"),
    );
}
