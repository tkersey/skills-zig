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
    if (shape.get("rules")) |raw_rules| {
        try definition_core.json.requireExactKeys(shape, &.{"rules"});
        return copyNativeRules(allocator, raw_rules, budget);
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
    if (raw == .array) {
        return copyNativeRules(allocator, raw, budget);
    }
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
    try validateConstraintScope(scope, input_names);
    if (terms) |term_map| {
        try validateConstraintTerms(allocator, constraints, term_map);
    }
    var rules = std.json.Array.init(allocator);
    if (constraints.get("laws")) |raw_laws| {
        var lowered = try lowerConstraintLaws(
            allocator,
            raw_laws,
            scope,
            terms,
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

fn copyNativeRules(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    budget: *ExpansionBudget,
) !std.json.Value {
    const source = try definition_core.json.array(raw);
    try budget.reserve(source.items.len);
    var rules = std.json.Array.init(allocator);
    try rules.appendSlice(source.items);
    return .{ .array = rules };
}

fn validateConstraintScope(
    scope: ?std.json.ObjectMap,
    input_names: []const []const u8,
) !void {
    const value = scope orelse return;
    try definition_core.json.requireExactKeys(value, &.{ "input", "path" });
    try definition_core.json.requireFields(value, &.{ "input", "path" });
    const input = try definition_core.json.requiredString(value, "input");
    if (!containsString(input_names, input)) {
        return error.UnknownConstraintInput;
    }
}

fn validateConstraintTerms(
    allocator: std.mem.Allocator,
    constraints: std.json.ObjectMap,
    terms: std.json.ObjectMap,
) !void {
    var use_sites = std.json.ObjectMap.empty;
    if (constraints.get("laws")) |laws| {
        try collectLawTermUses(allocator, laws, &use_sites, 0);
    }
    const raw_state = constraints.get("state") orelse {
        return requireUsedDeclarationNames(
            terms,
            use_sites,
            error.UnusedLawTerm,
        );
    };
    const state = try definition_core.json.object(raw_state);
    if (state.get("admissions")) |raw_admissions| {
        const admissions = try definition_core.json.array(raw_admissions);
        for (admissions.items) |raw_admission| {
            const admission = try definition_core.json.object(raw_admission);
            if (admission.get("laws")) |laws| {
                try collectLawTermUses(allocator, laws, &use_sites, 0);
            }
        }
    }
    try requireUsedDeclarationNames(terms, use_sites, error.UnusedLawTerm);
}

fn lowerConstraintLaws(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    scope: ?std.json.ObjectMap,
    terms: ?std.json.ObjectMap,
    budget: *ExpansionBudget,
) !std.json.Array {
    const input = if (scope) |value|
        try definition_core.json.requiredString(value, "input")
    else
        null;
    const path = if (scope) |value|
        try definition_core.json.requiredString(value, "path")
    else
        null;
    return lowerExpressions(
        allocator,
        try definition_core.json.array(raw),
        input,
        path,
        terms,
        true,
        budget,
    );
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
    var stack: std.ArrayList(NodeTask) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .lower = .{
        .raw = raw,
        .input = input,
        .path = path,
        .suppress_presence = suppress_presence,
        .types = types,
        .allow_types = allow_types,
        .rules = rules,
    } });
    while (stack.pop()) |task| {
        try runNodeTask(allocator, task, budget, &stack);
        if (stack.items.len > ExpansionBudget.max_emitted) {
            return error.SourceGraphExpansionLimitExceeded;
        }
    }
}

const NodeWork = struct {
    raw: std.json.Value,
    input: ?[]const u8,
    path: []const u8,
    suppress_presence: bool,
    types: ?std.json.ObjectMap,
    allow_types: bool,
    rules: *std.json.Array,
};

const NodeContainerWork = struct {
    source: std.json.Value,
    operator: []const u8,
    parent: NodeWork,
};

const NodeFinishWork = struct {
    operator: []const u8,
    input: ?[]const u8,
    path: []const u8,
    rules: *std.json.Array,
    children: *std.json.Array,
};

const TaggedVariantWork = struct {
    value: ?std.json.Value,
    kind: ?std.json.Value,
    rules: *std.json.Array,
};

const NodeTask = union(enum) {
    lower: NodeWork,
    emit: struct {
        rules: *std.json.Array,
        rule: std.json.Value,
    },
    container: NodeContainerWork,
    finish_container: NodeFinishWork,
    one_of: struct {
        variants: std.json.Array,
        parent: NodeWork,
    },
    finish_one_of: struct {
        parent: NodeWork,
        variants: []*std.json.Array,
    },
    tagged: struct {
        raw: std.json.Value,
        parent: NodeWork,
    },
    finish_tagged: struct {
        parent: NodeWork,
        tag: ?std.json.Value,
        variants: []TaggedVariantWork,
    },
    laws: struct {
        raw: std.json.Value,
        parent: NodeWork,
    },
    fields: struct {
        fields: std.json.ObjectMap,
        parent: NodeWork,
    },
    finish_optional: struct {
        parent: NodeWork,
        children: *std.json.Array,
        allow_null: bool,
    },
};

fn runNodeTask(
    allocator: std.mem.Allocator,
    task: NodeTask,
    budget: *ExpansionBudget,
    stack: *std.ArrayList(NodeTask),
) !void {
    switch (task) {
        .lower => |work| try scheduleNode(
            allocator,
            work,
            budget,
            stack,
        ),
        .emit => |work| try appendRule(budget, work.rules, work.rule),
        .container => |work| try scheduleNodeContainer(allocator, work, stack),
        .finish_container => |work| try finishNodeContainer(
            allocator,
            work,
            budget,
        ),
        .one_of => |work| try scheduleNodeOneOf(allocator, work, stack),
        .finish_one_of => |work| try finishNodeOneOf(
            allocator,
            work,
            budget,
        ),
        .tagged => |work| try scheduleNodeTagged(allocator, work, stack),
        .finish_tagged => |work| try finishNodeTagged(
            allocator,
            work,
            budget,
        ),
        .laws => |work| try appendNodeLaws(allocator, work, budget),
        .fields => |work| try scheduleNodeFields(allocator, work, stack),
        .finish_optional => |work| try finishOptionalNode(
            allocator,
            work,
            budget,
        ),
    }
}

fn scheduleNode(
    allocator: std.mem.Allocator,
    initial: NodeWork,
    budget: *ExpansionBudget,
    stack: *std.ArrayList(NodeTask),
) !void {
    var work = initial;
    if (work.raw == .array) {
        const reference = try definition_core.json.array(work.raw);
        if (!work.allow_types or reference.items.len != 2 or
            !std.mem.eql(u8, try definition_core.json.string(reference.items[0]), "use"))
        {
            return error.InvalidDocumentTypeReference;
        }
        const type_map = work.types orelse return error.UnknownDocumentType;
        const name = try definition_core.json.string(reference.items[1]);
        work.raw = type_map.get(name) orelse return error.UnknownDocumentType;
        work.allow_types = false;
        if (work.raw == .array) return error.NestedDocumentTypeReference;
    }
    const node = try definition_core.json.object(work.raw);
    try definition_core.json.requireExactKeys(node, &node_keys);
    if (!work.suppress_presence and
        try scheduleNodePresence(allocator, work, node, budget, stack))
    {
        return;
    }
    try scheduleNodeBody(allocator, work, node, stack);
}

fn scheduleNodePresence(
    allocator: std.mem.Allocator,
    work: NodeWork,
    node: std.json.ObjectMap,
    budget: *ExpansionBudget,
    stack: *std.ArrayList(NodeTask),
) !bool {
    if (try optionalBool(node, "forbidden", false)) {
        try appendRule(
            budget,
            work.rules,
            try makeRule(allocator, "field-absent", work.input, work.path, null),
        );
        return true;
    }
    const presence = try optionalPresence(node);
    const if_present = try ifPresentPresence(node);
    if (presence != .required or if_present != .required) {
        const children = try allocator.create(std.json.Array);
        children.* = std.json.Array.init(allocator);
        try stack.append(allocator, .{ .finish_optional = .{
            .parent = work,
            .children = children,
            .allow_null = presence == .nullable or if_present == .nullable,
        } });
        var child = work;
        child.input = null;
        child.path = "";
        child.suppress_presence = true;
        child.rules = children;
        try stack.append(allocator, .{ .lower = child });
        return true;
    }
    if (!try optionalBool(node, "required", false)) return false;
    try appendRule(
        budget,
        work.rules,
        try makeRule(allocator, "required-field", work.input, work.path, null),
    );
    var child = work;
    child.suppress_presence = true;
    try stack.append(allocator, .{ .lower = child });
    return true;
}

fn finishOptionalNode(
    allocator: std.mem.Allocator,
    work: @FieldType(NodeTask, "finish_optional"),
    budget: *ExpansionBudget,
) !void {
    if (work.children.items.len == 0) {
        work.children.deinit();
        return;
    }
    var config = std.json.ObjectMap.empty;
    try config.put(allocator, "rules", .{ .array = work.children.* });
    if (work.allow_null) {
        try config.put(allocator, "allow_null", .{ .bool = true });
    }
    try appendRule(
        budget,
        work.parent.rules,
        try makeRule(
            allocator,
            "optional-field",
            work.parent.input,
            work.parent.path,
            .{ .object = config },
        ),
    );
}

fn scheduleNodeBody(
    allocator: std.mem.Allocator,
    work: NodeWork,
    node: std.json.ObjectMap,
    stack: *std.ArrayList(NodeTask),
) !void {
    var tasks: std.ArrayList(NodeTask) = .empty;
    defer tasks.deinit(allocator);
    try queueNodeObjectRule(allocator, work, node, &tasks);
    try queueNodeScalarRules(allocator, work, node, &tasks);
    try queueNodeFormatRules(allocator, work, node, &tasks);
    try queueNodeIdentityRules(allocator, work, node, &tasks);
    try queueNodeCollectionRules(allocator, work, node, &tasks);
    try queueNodeClosingRules(allocator, work, node, &tasks);
    var index = tasks.items.len;
    while (index > 0) {
        index -= 1;
        try stack.append(allocator, tasks.items[index]);
    }
}

fn queueNodeRule(
    allocator: std.mem.Allocator,
    tasks: *std.ArrayList(NodeTask),
    rules: *std.json.Array,
    rule: std.json.Value,
) !void {
    try tasks.append(allocator, .{ .emit = .{
        .rules = rules,
        .rule = rule,
    } });
}

fn queueNodeObjectRule(
    allocator: std.mem.Allocator,
    work: NodeWork,
    node: std.json.ObjectMap,
    tasks: *std.ArrayList(NodeTask),
) !void {
    const raw = node.get("object") orelse return;
    try queueNodeRule(
        allocator,
        tasks,
        work.rules,
        try lowerObjectRule(
            allocator,
            node,
            work.input,
            work.path,
            try definition_core.json.string(raw),
            work.types,
            work.allow_types,
        ),
    );
}

fn queueNodeScalarRules(
    allocator: std.mem.Allocator,
    work: NodeWork,
    node: std.json.ObjectMap,
    tasks: *std.ArrayList(NodeTask),
) !void {
    if (node.get("scalar")) |raw| {
        var config = std.json.ObjectMap.empty;
        try config.put(allocator, "type", raw);
        try queueNodeRule(
            allocator,
            tasks,
            work.rules,
            try makeRule(
                allocator,
                "scalar-type",
                work.input,
                work.path,
                .{ .object = config },
            ),
        );
    }
    inline for (.{
        .{ "string", "bounded-string" },
        .{ "number", "bounded-number" },
        .{ "array", "bounded-array" },
        .{ "object_bounds", "bounded-object" },
        .{ "regex", "regex" },
    }) |entry| {
        if (node.get(entry[0])) |config| {
            try queueNodeRule(
                allocator,
                tasks,
                work.rules,
                try makeRule(allocator, entry[1], work.input, work.path, config),
            );
        }
    }
}

fn queueNodeFormatRules(
    allocator: std.mem.Allocator,
    work: NodeWork,
    node: std.json.ObjectMap,
    tasks: *std.ArrayList(NodeTask),
) !void {
    if (node.get("enum")) |values| {
        var config = std.json.ObjectMap.empty;
        try config.put(allocator, "values", values);
        try queueNodeRule(
            allocator,
            tasks,
            work.rules,
            try makeRule(
                allocator,
                "enum",
                work.input,
                work.path,
                .{ .object = config },
            ),
        );
    }
    if (node.get("format")) |raw| {
        var format: []const u8 = undefined;
        var rule_config: ?std.json.Value = null;
        switch (raw) {
            .string => |value| format = value,
            .object => |object| configured: {
                try definition_core.json.requireExactKeys(
                    object,
                    &.{ "kind", "allow_bare" },
                );
                try definition_core.json.requireFields(object, &.{"kind"});
                format = try definition_core.json.requiredString(
                    object,
                    "kind",
                );
                if (!std.mem.eql(u8, format, "digest")) {
                    return error.UnsupportedDocumentFormat;
                }
                var config = std.json.ObjectMap.empty;
                if (try optionalBool(object, "allow_bare", false)) {
                    try config.put(allocator, "allow_bare", .{ .bool = true });
                }
                rule_config = .{ .object = config };
                break :configured;
            },
            else => return error.UnsupportedDocumentFormat,
        }
        if (!std.mem.eql(u8, format, "digest") and
            !std.mem.eql(u8, format, "timestamp"))
        {
            return error.UnsupportedDocumentFormat;
        }
        try queueNodeRule(
            allocator,
            tasks,
            work.rules,
            try makeRule(
                allocator,
                format,
                work.input,
                work.path,
                rule_config,
            ),
        );
    }
}

fn queueNodeIdentityRules(
    allocator: std.mem.Allocator,
    work: NodeWork,
    node: std.json.ObjectMap,
    tasks: *std.ArrayList(NodeTask),
) !void {
    inline for (.{
        .{ "identifier", "safe-identifier" },
        .{ "relative_path", "safe-relative-path" },
        .{ "sorted", "sorted" },
    }) |entry| {
        if (node.get(entry[0])) |config| {
            try queueNodeRule(
                allocator,
                tasks,
                work.rules,
                try makeRule(
                    allocator,
                    entry[1],
                    work.input,
                    work.path,
                    boolAsEmptyObject(config),
                ),
            );
        }
    }
    try queueNodeDefinitionRule(allocator, work, node, tasks);
    if (try optionalBool(node, "unique", false)) {
        try queueNodeRule(
            allocator,
            tasks,
            work.rules,
            try makeRule(allocator, "unique", work.input, work.path, null),
        );
    }
}

fn queueNodeDefinitionRule(
    allocator: std.mem.Allocator,
    work: NodeWork,
    node: std.json.ObjectMap,
    tasks: *std.ArrayList(NodeTask),
) !void {
    inline for (.{ .{ "definition", "definition-ref", "definition" }, .{
        "key",
        "keyed-unique",
        "key",
    } }) |entry| {
        if (node.get(entry[0])) |raw| {
            var config = std.json.ObjectMap.empty;
            try config.put(allocator, entry[2], raw);
            try queueNodeRule(
                allocator,
                tasks,
                work.rules,
                try makeRule(
                    allocator,
                    entry[1],
                    work.input,
                    work.path,
                    .{ .object = config },
                ),
            );
        }
    }
}

fn queueNodeCollectionRules(
    allocator: std.mem.Allocator,
    work: NodeWork,
    node: std.json.ObjectMap,
    tasks: *std.ArrayList(NodeTask),
) !void {
    if (node.get("items")) |source| {
        try tasks.append(allocator, .{ .container = .{
            .source = source,
            .operator = "all",
            .parent = work,
        } });
    }
    if (node.get("values")) |source| {
        try tasks.append(allocator, .{ .container = .{
            .source = source,
            .operator = "object-values",
            .parent = work,
        } });
    }
    if (node.get("one_of")) |raw| {
        try tasks.append(allocator, .{ .one_of = .{
            .variants = try definition_core.json.array(raw),
            .parent = work,
        } });
    }
    if (node.get("tagged")) |raw| {
        try tasks.append(allocator, .{ .tagged = .{
            .raw = raw,
            .parent = work,
        } });
    }
}

fn queueNodeClosingRules(
    allocator: std.mem.Allocator,
    work: NodeWork,
    node: std.json.ObjectMap,
    tasks: *std.ArrayList(NodeTask),
) !void {
    inline for (.{
        .{ "sha256", "sha256" },
        .{ "declared_field_values", "declared-field-values" },
        .{ "forbidden_keys", "forbidden-object-keys" },
    }) |entry| {
        if (node.get(entry[0])) |config| {
            try queueNodeRule(
                allocator,
                tasks,
                work.rules,
                try makeRule(allocator, entry[1], work.input, work.path, config),
            );
        }
    }
    if (node.get("event_envelope")) |config| {
        if (work.path.len != 0) return error.EventEnvelopeMustBeDocumentRoot;
        try queueNodeRule(
            allocator,
            tasks,
            work.rules,
            try makeRule(allocator, "event-envelope", work.input, null, config),
        );
    }
    if (node.get("laws")) |raw| {
        try tasks.append(allocator, .{ .laws = .{ .raw = raw, .parent = work } });
    }
    if (node.get("fields")) |raw| {
        try tasks.append(allocator, .{ .fields = .{
            .fields = try definition_core.json.object(raw),
            .parent = work,
        } });
    }
}

fn scheduleNodeContainer(
    allocator: std.mem.Allocator,
    work: NodeContainerWork,
    stack: *std.ArrayList(NodeTask),
) !void {
    const children = try allocator.create(std.json.Array);
    children.* = std.json.Array.init(allocator);
    try stack.append(allocator, .{ .finish_container = .{
        .operator = work.operator,
        .input = work.parent.input,
        .path = work.parent.path,
        .rules = work.parent.rules,
        .children = children,
    } });
    try stack.append(allocator, .{ .lower = .{
        .raw = work.source,
        .input = null,
        .path = "",
        .suppress_presence = false,
        .types = work.parent.types,
        .allow_types = work.parent.allow_types,
        .rules = children,
    } });
}

fn finishNodeContainer(
    allocator: std.mem.Allocator,
    work: NodeFinishWork,
    budget: *ExpansionBudget,
) !void {
    var config = std.json.ObjectMap.empty;
    try config.put(allocator, "rules", .{ .array = work.children.* });
    try appendRule(
        budget,
        work.rules,
        try makeRule(
            allocator,
            work.operator,
            work.input,
            work.path,
            .{ .object = config },
        ),
    );
}

fn scheduleNodeOneOf(
    allocator: std.mem.Allocator,
    work: @FieldType(NodeTask, "one_of"),
    stack: *std.ArrayList(NodeTask),
) !void {
    const children = try allocator.alloc(*std.json.Array, work.variants.items.len);
    for (children) |*child| {
        child.* = try allocator.create(std.json.Array);
        child.*.* = std.json.Array.init(allocator);
    }
    try stack.append(allocator, .{ .finish_one_of = .{
        .parent = work.parent,
        .variants = children,
    } });
    var index = work.variants.items.len;
    while (index > 0) {
        index -= 1;
        try stack.append(allocator, .{ .lower = .{
            .raw = work.variants.items[index],
            .input = null,
            .path = "",
            .suppress_presence = false,
            .types = work.parent.types,
            .allow_types = work.parent.allow_types,
            .rules = children[index],
        } });
    }
}

fn finishNodeOneOf(
    allocator: std.mem.Allocator,
    work: @FieldType(NodeTask, "finish_one_of"),
    budget: *ExpansionBudget,
) !void {
    var lowered = std.json.Array.init(allocator);
    for (work.variants) |rules| {
        if (rules.items.len != 1) return error.InvalidOneOfDocumentVariant;
        try lowered.append(rules.items[0]);
    }
    var config = std.json.ObjectMap.empty;
    try config.put(allocator, "rules", .{ .array = lowered });
    try appendRule(
        budget,
        work.parent.rules,
        try makeRule(
            allocator,
            "one-of",
            work.parent.input,
            work.parent.path,
            .{ .object = config },
        ),
    );
}

fn scheduleNodeTagged(
    allocator: std.mem.Allocator,
    work: @FieldType(NodeTask, "tagged"),
    stack: *std.ArrayList(NodeTask),
) !void {
    const tagged = try definition_core.json.object(work.raw);
    try definition_core.json.requireExactKeys(tagged, &.{ "tag", "variants" });
    const raw_variants = try definition_core.json.array(
        try definition_core.json.field(tagged, "variants"),
    );
    const variants = try allocator.alloc(TaggedVariantWork, raw_variants.items.len);
    for (raw_variants.items, variants) |raw_variant, *variant| {
        const object = try definition_core.json.object(raw_variant);
        try definition_core.json.requireExactKeys(object, &.{
            "value",
            "kind",
            "node",
        });
        const value = object.get("value");
        const kind = object.get("kind");
        if ((value == null) == (kind == null)) {
            return error.InvalidTaggedDocumentVariant;
        }
        variant.* = .{
            .value = value,
            .kind = kind,
            .rules = try allocator.create(std.json.Array),
        };
        variant.rules.* = std.json.Array.init(allocator);
    }
    try stack.append(allocator, .{ .finish_tagged = .{
        .parent = work.parent,
        .tag = tagged.get("tag"),
        .variants = variants,
    } });
    try scheduleTaggedVariantNodes(allocator, raw_variants, work.parent, variants, stack);
}

fn scheduleTaggedVariantNodes(
    allocator: std.mem.Allocator,
    raw: std.json.Array,
    parent: NodeWork,
    variants: []TaggedVariantWork,
    stack: *std.ArrayList(NodeTask),
) !void {
    var index = raw.items.len;
    while (index > 0) {
        index -= 1;
        const object = try definition_core.json.object(raw.items[index]);
        try stack.append(allocator, .{ .lower = .{
            .raw = try definition_core.json.field(object, "node"),
            .input = null,
            .path = "",
            .suppress_presence = false,
            .types = parent.types,
            .allow_types = parent.allow_types,
            .rules = variants[index].rules,
        } });
    }
}

fn finishNodeTagged(
    allocator: std.mem.Allocator,
    work: @FieldType(NodeTask, "finish_tagged"),
    budget: *ExpansionBudget,
) !void {
    var variants = std.json.Array.init(allocator);
    for (work.variants) |variant| {
        var lowered = std.json.ObjectMap.empty;
        if (variant.value) |value| try lowered.put(allocator, "value", value);
        if (variant.kind) |kind| try lowered.put(allocator, "kind", kind);
        try lowered.put(allocator, "rules", .{ .array = variant.rules.* });
        try variants.append(.{ .object = lowered });
    }
    var config = std.json.ObjectMap.empty;
    if (work.tag) |tag| try config.put(allocator, "tag", tag);
    try config.put(allocator, "variants", .{ .array = variants });
    try appendRule(
        budget,
        work.parent.rules,
        try makeRule(
            allocator,
            "tagged-union",
            work.parent.input,
            work.parent.path,
            .{ .object = config },
        ),
    );
}

fn appendNodeLaws(
    allocator: std.mem.Allocator,
    work: @FieldType(NodeTask, "laws"),
    budget: *ExpansionBudget,
) !void {
    var lowered = try lowerExpressions(
        allocator,
        try definition_core.json.array(work.raw),
        work.parent.input,
        work.parent.path,
        null,
        false,
        budget,
    );
    defer lowered.deinit();
    try work.parent.rules.appendSlice(lowered.items);
}

fn scheduleNodeFields(
    allocator: std.mem.Allocator,
    work: @FieldType(NodeTask, "fields"),
    stack: *std.ArrayList(NodeTask),
) !void {
    var children: std.ArrayList(NodeWork) = .empty;
    defer children.deinit(allocator);
    var iterator = work.fields.iterator();
    while (iterator.next()) |entry| {
        try children.append(allocator, .{
            .raw = entry.value_ptr.*,
            .input = work.parent.input,
            .path = try joinPointer(
                allocator,
                work.parent.path,
                entry.key_ptr.*,
            ),
            .suppress_presence = false,
            .types = work.parent.types,
            .allow_types = work.parent.allow_types,
            .rules = work.parent.rules,
        });
    }
    var index = children.items.len;
    while (index > 0) {
        index -= 1;
        try stack.append(allocator, .{ .lower = children.items[index] });
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
    try appendConfiguredRule(
        allocator,
        rules,
        budget,
        "sequence",
        "start",
        try definition_core.json.field(event_log, "start"),
    );
    try appendConfiguredRule(
        allocator,
        rules,
        budget,
        "previous-digest",
        "genesis",
        try definition_core.json.field(event_log, "genesis"),
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
    try appendConfiguredRule(
        allocator,
        rules,
        budget,
        "event-kinds",
        "values",
        try definition_core.json.field(event_log, "kinds"),
    );
}

fn appendConfiguredRule(
    allocator: std.mem.Allocator,
    rules: *std.json.Array,
    budget: *ExpansionBudget,
    operator: []const u8,
    key: []const u8,
    value: std.json.Value,
) !void {
    var config = std.json.ObjectMap.empty;
    try config.put(allocator, key, value);
    try appendRule(
        budget,
        rules,
        try makeRule(allocator, operator, null, null, .{ .object = config }),
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
    try reducer.put(
        allocator,
        "registers",
        .{ .array = try lowerStateRegisters(
            allocator,
            try definition_core.json.field(state, "registers"),
        ) },
    );
    try reducer.put(
        allocator,
        "sets",
        .{ .array = try lowerStateSets(
            allocator,
            try definition_core.json.field(state, "sets"),
        ) },
    );
    try reducer.put(
        allocator,
        "admissions",
        .{ .array = try lowerStateAdmissions(
            allocator,
            try definition_core.json.field(state, "admissions"),
            terms,
            budget,
        ) },
    );
    return makeRule(
        allocator,
        "reducer",
        null,
        null,
        .{ .object = reducer },
    );
}

fn lowerStateRegisters(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) !std.json.Array {
    var registers = std.json.Array.init(allocator);
    var register_iterator = (try definition_core.json.object(raw)).iterator();
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
    return registers;
}

fn lowerStateSets(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) !std.json.Array {
    var sets = std.json.Array.init(allocator);
    var set_iterator = (try definition_core.json.object(raw)).iterator();
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
    return sets;
}

fn lowerStateAdmissions(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    terms: ?std.json.ObjectMap,
    budget: *ExpansionBudget,
) !std.json.Array {
    const raw_admissions = try definition_core.json.array(raw);
    var admissions = std.json.Array.init(allocator);
    for (raw_admissions.items) |raw_admission| {
        try admissions.append(.{ .object = try lowerStateAdmission(
            allocator,
            try definition_core.json.object(raw_admission),
            terms,
            budget,
        ) });
    }
    return admissions;
}

fn lowerStateAdmission(
    allocator: std.mem.Allocator,
    admission: std.json.ObjectMap,
    terms: ?std.json.ObjectMap,
    budget: *ExpansionBudget,
) !std.json.ObjectMap {
    try definition_core.json.requireExactKeys(admission, &.{
        "on",
        "requires",
        "forbids",
        "laws",
        "current_laws",
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
    if (admission.get("current_laws")) |laws| {
        const current_laws = try lowerExpressions(
            allocator,
            try definition_core.json.array(laws),
            null,
            null,
            terms,
            true,
            budget,
        );
        try lowered.put(allocator, "current_rules", .{ .array = current_laws });
    }
    const admission_actions = if (admission.get("actions")) |actions|
        try lowerStateActions(
            allocator,
            try definition_core.json.array(actions),
        )
    else
        std.json.Array.init(allocator);
    try lowered.put(allocator, "actions", .{ .array = admission_actions });
    return lowered;
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
        try lowered_plans.put(
            allocator,
            entry.key_ptr.*,
            .{ .object = try lowerEventOperation(
                allocator,
                event,
                entry.value_ptr.*,
                budget,
            ) },
        );
    }
    return lowered_plans;
}

fn lowerEventOperation(
    allocator: std.mem.Allocator,
    event: std.json.ObjectMap,
    raw_plan: std.json.Value,
    budget: *ExpansionBudget,
) !std.json.ObjectMap {
    try budget.reserve(1);
    const kind = switch (raw_plan) {
        .string => |value| value,
        .object => |plan| try definition_core.json.requiredString(plan, "kind"),
        else => return error.InvalidEventOperationPlan,
    };
    const plan = switch (raw_plan) {
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
    var effect = std.json.ObjectMap.empty;
    try effect.put(
        allocator,
        "op",
        plan.get("effect") orelse
            try definition_core.json.field(event, "effect"),
    );
    try effect.put(
        allocator,
        "slot",
        try definition_core.json.field(event, "slot"),
    );
    try effect.put(
        allocator,
        "input",
        plan.get("input") orelse try definition_core.json.field(event, "input"),
    );
    try effect.put(allocator, "event", .{
        .object = try lowerEventPlan(allocator, event, plan, kind, budget),
    });
    var effects = std.json.Array.init(allocator);
    try effects.append(.{ .object = effect });
    var operation = std.json.ObjectMap.empty;
    try operation.put(allocator, "effects", .{ .array = effects });
    return operation;
}

fn lowerEventPlan(
    allocator: std.mem.Allocator,
    event: std.json.ObjectMap,
    plan: std.json.ObjectMap,
    kind: []const u8,
    budget: *ExpansionBudget,
) !std.json.ObjectMap {
    var lowered = std.json.ObjectMap.empty;
    try lowered.put(
        allocator,
        "mode",
        try definition_core.json.field(event, "mode"),
    );
    try lowered.put(
        allocator,
        "body_input_field",
        try definition_core.json.field(event, "body_input"),
    );
    const event_fields = try definition_core.json.object(
        try definition_core.json.field(event, "fields"),
    );
    const overrides = if (plan.get("fields")) |fields|
        try definition_core.json.object(fields)
    else
        null;
    try lowered.put(allocator, "fields", .{
        .array = try lowerEventFields(
            allocator,
            event_fields,
            overrides,
            kind,
            budget,
        ),
    });
    try putEventRequest(allocator, &lowered, event, plan, kind, budget);
    try putEventGenerate(allocator, &lowered, plan, budget);
    try putEventBody(allocator, &lowered, plan, budget);
    try putEventForbidden(allocator, &lowered, event, plan);
    return lowered;
}

fn putEventRequest(
    allocator: std.mem.Allocator,
    lowered: *std.json.ObjectMap,
    event: std.json.ObjectMap,
    plan: std.json.ObjectMap,
    kind: []const u8,
    budget: *ExpansionBudget,
) !void {
    const source = plan.get("request") orelse event.get("request") orelse .null;
    if (source == .null) return;
    try lowered.put(allocator, "request_literals", .{
        .array = try lowerLiteralFields(
            allocator,
            try definition_core.json.object(source),
            kind,
            budget,
        ),
    });
}

fn putEventGenerate(
    allocator: std.mem.Allocator,
    lowered: *std.json.ObjectMap,
    plan: std.json.ObjectMap,
    budget: *ExpansionBudget,
) !void {
    const generate = plan.get("generate") orelse return;
    try lowered.put(allocator, "generate", .{
        .array = try lowerGeneratedFields(
            allocator,
            try definition_core.json.object(generate),
            budget,
        ),
    });
}

fn putEventBody(
    allocator: std.mem.Allocator,
    lowered: *std.json.ObjectMap,
    plan: std.json.ObjectMap,
    budget: *ExpansionBudget,
) !void {
    const body = plan.get("body") orelse return;
    try lowered.put(allocator, "body_fields", .{
        .array = try lowerConfiguredFields(
            allocator,
            try definition_core.json.object(body),
            budget,
        ),
    });
}

fn putEventForbidden(
    allocator: std.mem.Allocator,
    lowered: *std.json.ObjectMap,
    event: std.json.ObjectMap,
    plan: std.json.ObjectMap,
) !void {
    const forbidden = plan.get("forbid") orelse event.get("forbid") orelse
        .null;
    if (forbidden == .null) return;
    const values = try definition_core.json.array(forbidden);
    if (values.items.len != 0) {
        try lowered.put(allocator, "forbidden_parameters", forbidden);
    }
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
    var selected = raw;
    var terms_allowed = allow_terms;
    for (0..2) |_| {
        const candidate = try definition_core.json.array(selected);
        if (candidate.items.len == 0) return error.InvalidLawExpression;
        const candidate_operator = try definition_core.json.string(
            candidate.items[0],
        );
        if (!std.mem.eql(u8, candidate_operator, "use")) break;
        if (!terms_allowed or candidate.items.len != 2) {
            return error.InvalidLawTerm;
        }
        const name = try definition_core.json.string(candidate.items[1]);
        const term_map = terms orelse return error.UnknownLawTerm;
        selected = term_map.get(name) orelse return error.UnknownLawTerm;
        terms_allowed = false;
    }
    const expression = try definition_core.json.array(selected);
    if (expression.items.len == 0) return error.InvalidLawExpression;
    const operator = try definition_core.json.string(expression.items[0]);
    if (expression.items.len > 2) {
        return lowerPositionalExpression(
            allocator,
            expression,
            inherited_input,
            inherited_path,
            terms,
            terms_allowed,
            budget,
        );
    }
    return lowerObjectExpression(
        allocator,
        expression,
        operator,
        inherited_input,
        inherited_path,
        terms,
        terms_allowed,
        budget,
    );
}

fn lowerObjectExpression(
    allocator: std.mem.Allocator,
    expression: std.json.Array,
    operator: []const u8,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) anyerror!std.json.Value {
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
    const root = try allocator.create(std.json.Value);
    var stack: std.ArrayList(NestedTask) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .transform = .{
        .key = key,
        .raw = raw,
        .output = root,
    } });
    while (stack.pop()) |task| {
        try runNestedTask(
            allocator,
            task,
            terms,
            allow_terms,
            budget,
            &stack,
        );
        if (stack.items.len > ExpansionBudget.max_emitted) {
            return error.SourceGraphExpansionLimitExceeded;
        }
    }
    return root.*;
}

const NestedTransform = struct {
    key: []const u8,
    raw: std.json.Value,
    output: *std.json.Value,
};

const NestedObjectEntry = struct {
    key: []const u8,
    value: *std.json.Value,
};

const NestedTask = union(enum) {
    transform: NestedTransform,
    finish_object: struct {
        output: *std.json.Value,
        object: *std.json.ObjectMap,
    },
    put_object: struct {
        object: *std.json.ObjectMap,
        entry: NestedObjectEntry,
    },
    finish_array: struct {
        output: *std.json.Value,
        array: *std.json.Array,
    },
    append_array: struct {
        array: *std.json.Array,
        value: *std.json.Value,
    },
};

fn runNestedTask(
    allocator: std.mem.Allocator,
    task: NestedTask,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
    stack: *std.ArrayList(NestedTask),
) !void {
    switch (task) {
        .transform => |work| try transformNestedValue(
            allocator,
            work,
            terms,
            allow_terms,
            budget,
            stack,
        ),
        .finish_object => |work| work.output.* = .{ .object = work.object.* },
        .put_object => |work| try work.object.put(
            allocator,
            work.entry.key,
            work.entry.value.*,
        ),
        .finish_array => |work| work.output.* = .{ .array = work.array.* },
        .append_array => |work| try work.array.append(work.value.*),
    }
}

fn transformNestedValue(
    allocator: std.mem.Allocator,
    work: NestedTransform,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
    stack: *std.ArrayList(NestedTask),
) !void {
    if (isRuleListKey(work.key)) {
        work.output.* = .{ .array = try lowerNestedRuleList(
            allocator,
            try definition_core.json.array(work.raw),
            terms,
            allow_terms,
            budget,
        ) };
        return;
    }
    switch (work.raw) {
        .object => |object| try scheduleNestedObject(
            allocator,
            work.output,
            object,
            stack,
        ),
        .array => |array| try scheduleNestedArray(
            allocator,
            work.output,
            array,
            stack,
        ),
        else => work.output.* = work.raw,
    }
}

fn scheduleNestedObject(
    allocator: std.mem.Allocator,
    output: *std.json.Value,
    source: std.json.ObjectMap,
    stack: *std.ArrayList(NestedTask),
) !void {
    const object = try allocator.create(std.json.ObjectMap);
    object.* = .empty;
    try stack.append(allocator, .{ .finish_object = .{
        .output = output,
        .object = object,
    } });
    var entries: std.ArrayList(NestedTransform) = .empty;
    defer entries.deinit(allocator);
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        try entries.append(allocator, .{
            .key = entry.key_ptr.*,
            .raw = entry.value_ptr.*,
            .output = try allocator.create(std.json.Value),
        });
    }
    var index = entries.items.len;
    while (index > 0) {
        index -= 1;
        const entry = entries.items[index];
        try stack.append(allocator, .{ .put_object = .{
            .object = object,
            .entry = .{ .key = entry.key, .value = entry.output },
        } });
        try stack.append(allocator, .{ .transform = entry });
    }
}

fn scheduleNestedArray(
    allocator: std.mem.Allocator,
    output: *std.json.Value,
    source: std.json.Array,
    stack: *std.ArrayList(NestedTask),
) !void {
    const array = try allocator.create(std.json.Array);
    array.* = std.json.Array.init(allocator);
    try stack.append(allocator, .{ .finish_array = .{
        .output = output,
        .array = array,
    } });
    var index = source.items.len;
    while (index > 0) {
        index -= 1;
        const value = try allocator.create(std.json.Value);
        try stack.append(allocator, .{ .append_array = .{
            .array = array,
            .value = value,
        } });
        try stack.append(allocator, .{ .transform = .{
            .key = "",
            .raw = source.items[index],
            .output = value,
        } });
    }
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
    if (isSimplePositionalOperator(operator)) {
        return lowerSimplePositionalExpression(
            allocator,
            expression,
            operator,
            inherited_input,
            inherited_path,
        );
    }
    if (std.mem.eql(u8, operator, "all") or
        std.mem.eql(u8, operator, "any") or
        std.mem.eql(u8, operator, "none"))
    {
        return lowerQuantifiedExpression(
            allocator,
            expression,
            operator,
            inherited_input,
            inherited_path,
            terms,
            allow_terms,
            budget,
        );
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

fn isSimplePositionalOperator(operator: []const u8) bool {
    return isBinaryReferenceOperator(operator) or
        std.mem.eql(u8, operator, "definition-ref") or
        std.mem.eql(u8, operator, "bounded-array") or
        std.mem.eql(u8, operator, "bounded-number") or
        std.mem.eql(u8, operator, "enum");
}

fn lowerSimplePositionalExpression(
    allocator: std.mem.Allocator,
    expression: std.json.Array,
    operator: []const u8,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
) !std.json.Value {
    if (isBinaryReferenceOperator(operator)) {
        return lowerBinaryReferenceExpression(
            allocator,
            expression,
            operator,
            inherited_input,
            inherited_path,
        );
    }
    if (std.mem.eql(u8, operator, "definition-ref")) {
        return lowerDefinitionReferenceExpression(
            allocator,
            expression,
            inherited_input,
            inherited_path,
        );
    }
    if (std.mem.eql(u8, operator, "bounded-array") or
        std.mem.eql(u8, operator, "bounded-number"))
    {
        return lowerBoundedExpression(
            allocator,
            expression,
            operator,
            inherited_input,
            inherited_path,
        );
    }
    return lowerEnumExpression(
        allocator,
        expression,
        inherited_input,
        inherited_path,
    );
}

fn lowerBinaryReferenceExpression(
    allocator: std.mem.Allocator,
    expression: std.json.Array,
    operator: []const u8,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
) !std.json.Value {
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
        .string = try resolvedPath(allocator, left, inherited_path),
    });
    try result.put(allocator, "right", .{
        .string = try resolvedPath(allocator, right, inherited_path),
    });
    return .{ .object = result };
}

fn lowerDefinitionReferenceExpression(
    allocator: std.mem.Allocator,
    expression: std.json.Array,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
) !std.json.Value {
    if (expression.items.len != 3) return error.InvalidLawExpression;
    const subject = try compactReference(expression.items[1]);
    var result = std.json.ObjectMap.empty;
    try result.put(allocator, "op", .{ .string = "definition-ref" });
    try putIfPresent(
        allocator,
        &result,
        "input",
        resolvedInput(subject, inherited_input),
    );
    try result.put(allocator, "path", .{
        .string = try resolvedPath(allocator, subject, inherited_path),
    });
    try result.put(allocator, "definition", expression.items[2]);
    return .{ .object = result };
}

fn lowerBoundedExpression(
    allocator: std.mem.Allocator,
    expression: std.json.Array,
    operator: []const u8,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
) !std.json.Value {
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
        .string = try resolvedPath(allocator, subject, inherited_path),
    });
    if (expression.items[2] != .null) {
        try result.put(allocator, "min", expression.items[2]);
    }
    if (expression.items[3] != .null) {
        try result.put(allocator, "max", expression.items[3]);
    }
    return .{ .object = result };
}

fn lowerEnumExpression(
    allocator: std.mem.Allocator,
    expression: std.json.Array,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
) !std.json.Value {
    if (expression.items.len != 3) return error.InvalidLawExpression;
    const subject = try compactReference(expression.items[1]);
    var result = std.json.ObjectMap.empty;
    try result.put(allocator, "op", .{ .string = "enum" });
    try putIfPresent(
        allocator,
        &result,
        "input",
        resolvedInput(subject, inherited_input),
    );
    try result.put(allocator, "path", .{
        .string = try resolvedPath(allocator, subject, inherited_path),
    });
    try result.put(allocator, "values", expression.items[2]);
    return .{ .object = result };
}

fn lowerQuantifiedExpression(
    allocator: std.mem.Allocator,
    expression: std.json.Array,
    operator: []const u8,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) !std.json.Value {
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
        .string = try resolvedPath(allocator, subject, inherited_path),
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
    try putCompactConsequence(
        allocator,
        &result,
        expression.items[3],
        inherited_input,
        inherited_path,
        terms,
        allow_terms,
        budget,
    );
    return .{ .object = result };
}

fn putCompactConsequence(
    allocator: std.mem.Allocator,
    result: *std.json.ObjectMap,
    raw: std.json.Value,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) !void {
    switch (raw) {
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
            try definition_core.json.requireExactKeys(
                consequence,
                &.{ "then", "equals", "nonempty" },
            );
            const then = try compactReference(
                try definition_core.json.field(consequence, "then"),
            );
            try putIfPresent(
                allocator,
                result,
                "then_input",
                resolvedInput(then, inherited_input),
            );
            try result.put(allocator, "then", .{
                .string = try resolvedPath(allocator, then, inherited_path),
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
    const sources = try lowerCompactSources(
        allocator,
        raw_sources,
        inherited_input,
        inherited_path,
        terms,
        allow_terms,
        budget,
    );
    const targets = try lowerCompactTargets(
        allocator,
        raw_targets,
        inherited_input,
        inherited_path,
        terms,
        allow_terms,
        budget,
    );
    try result.put(allocator, "input", .{ .string = sources.input });
    if (!std.mem.eql(u8, sources.input, targets.input)) {
        try result.put(allocator, "target_input", .{ .string = targets.input });
    }
    const single = if (expression.items.len == 4)
        try applyCompactRelationOptions(
            allocator,
            &result,
            expression.items[3],
            terms,
            allow_terms,
            budget,
        )
    else
        false;
    if (single) {
        try flattenCompactRelation(
            allocator,
            &result,
            sources.values,
            targets.values,
        );
    } else {
        try result.put(allocator, "sources", .{ .array = sources.values });
        try result.put(allocator, "targets", .{ .array = targets.values });
    }
    return .{ .object = result };
}

const CompactEndpoints = struct {
    values: std.json.Array,
    input: []const u8,
};

fn lowerCompactSources(
    allocator: std.mem.Allocator,
    raw: std.json.Array,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) !CompactEndpoints {
    var values = std.json.Array.init(allocator);
    var common_input: ?[]const u8 = null;
    for (raw.items) |raw_endpoint| {
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
        if (common_input) |expected| {
            if (!std.mem.eql(u8, expected, input)) {
                return error.MixedRelationSourceInputs;
            }
        } else common_input = input;
        try values.append(.{ .object = endpoint.object });
    }
    return .{ .values = values, .input = common_input.? };
}

fn lowerCompactTargets(
    allocator: std.mem.Allocator,
    raw: std.json.Array,
    inherited_input: ?[]const u8,
    inherited_path: ?[]const u8,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) !CompactEndpoints {
    var values = std.json.Array.init(allocator);
    var common_input: ?[]const u8 = null;
    for (raw.items) |raw_endpoint| {
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
        if (common_input) |expected| {
            if (!std.mem.eql(u8, expected, input)) {
                return error.MixedRelationTargetInputs;
            }
        } else common_input = input;
        try values.append(.{ .object = endpoint.object });
    }
    return .{ .values = values, .input = common_input.? };
}

fn applyCompactRelationOptions(
    allocator: std.mem.Allocator,
    result: *std.json.ObjectMap,
    raw: std.json.Value,
    terms: ?std.json.ObjectMap,
    allow_terms: bool,
    budget: *ExpansionBudget,
) !bool {
    var single = false;
    const options = try definition_core.json.object(raw);
    var iterator = options.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "single")) {
            single = try definition_core.json.boolean(entry.value_ptr.*);
            continue;
        }
        try putNonOverridingReserved(
            allocator,
            result,
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
    return single;
}

fn flattenCompactRelation(
    allocator: std.mem.Allocator,
    result: *std.json.ObjectMap,
    sources: std.json.Array,
    targets: std.json.Array,
) !void {
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
    var stack: std.ArrayList(ValueDepth) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .value = raw, .depth = depth });
    while (stack.pop()) |current| {
        if (current.depth > 64) return error.ArtifactRuleDepthExceeded;
        if (try recordDocumentTypeUse(allocator, current.value, used)) continue;
        const node = try definition_core.json.object(current.value);
        try appendDocumentNodeChildren(
            allocator,
            &stack,
            node,
            current.depth + 1,
        );
    }
}

const ValueDepth = struct {
    value: std.json.Value,
    depth: usize,
};

fn recordDocumentTypeUse(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    used: *std.json.ObjectMap,
) !bool {
    if (raw != .array) return false;
    const reference = try definition_core.json.array(raw);
    if (reference.items.len == 2 and reference.items[0] == .string and
        std.mem.eql(u8, reference.items[0].string, "use"))
    {
        const name = try definition_core.json.string(reference.items[1]);
        try definition_core.json.safeIdentifier(name, 128);
        try used.put(allocator, name, .null);
    }
    return true;
}

fn appendDocumentNodeChildren(
    allocator: std.mem.Allocator,
    stack: *std.ArrayList(ValueDepth),
    node: std.json.ObjectMap,
    depth: usize,
) !void {
    if (node.get("fields")) |raw_fields| {
        var iterator = (try definition_core.json.object(raw_fields)).iterator();
        while (iterator.next()) |entry| {
            try stack.append(allocator, .{ .value = entry.value_ptr.*, .depth = depth });
        }
    }
    inline for (.{ "items", "values" }) |name| {
        if (node.get(name)) |child| {
            try stack.append(allocator, .{ .value = child, .depth = depth });
        }
    }
    if (node.get("one_of")) |raw_variants| {
        for ((try definition_core.json.array(raw_variants)).items) |variant| {
            try stack.append(allocator, .{ .value = variant, .depth = depth });
        }
    }
    if (node.get("tagged")) |raw_tagged| {
        const tagged = try definition_core.json.object(raw_tagged);
        const variants = try definition_core.json.array(
            try definition_core.json.field(tagged, "variants"),
        );
        for (variants.items) |raw_variant| {
            const variant = try definition_core.json.object(raw_variant);
            try stack.append(allocator, .{
                .value = try definition_core.json.field(variant, "node"),
                .depth = depth,
            });
        }
    }
    if (stack.items.len > ExpansionBudget.max_emitted) {
        return error.SourceGraphExpansionLimitExceeded;
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
    var stack: std.ArrayList(LawUseTask) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .laws = .{ .value = raw, .depth = depth } });
    while (stack.pop()) |task| {
        switch (task) {
            .laws => |current| try inspectLawList(
                allocator,
                current,
                used,
                &stack,
            ),
            .nested => |current| try inspectNestedLawValue(
                allocator,
                current,
                &stack,
            ),
        }
        if (stack.items.len > ExpansionBudget.max_emitted) {
            return error.SourceGraphExpansionLimitExceeded;
        }
    }
}

const LawUseTask = union(enum) {
    laws: ValueDepth,
    nested: ValueDepth,
};

fn inspectLawList(
    allocator: std.mem.Allocator,
    current: ValueDepth,
    used: *std.json.ObjectMap,
    stack: *std.ArrayList(LawUseTask),
) !void {
    if (current.depth > 64) return error.ArtifactRuleDepthExceeded;
    const laws = try definition_core.json.array(current.value);
    for (laws.items) |raw_expression| {
        const expression = try definition_core.json.array(raw_expression);
        if (expression.items.len == 0) continue;
        const operator = try definition_core.json.string(expression.items[0]);
        if (std.mem.eql(u8, operator, "use") and expression.items.len == 2) {
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
            try stack.append(allocator, .{
                .laws = .{
                    .value = expression.items[2],
                    .depth = current.depth + 1,
                },
            });
        }
        if (std.mem.eql(u8, operator, "implies") and
            expression.items.len == 4 and expression.items[3] == .array)
        {
            try stack.append(allocator, .{
                .laws = .{
                    .value = expression.items[3],
                    .depth = current.depth + 1,
                },
            });
        }
        for (expression.items[1..]) |item| {
            try stack.append(allocator, .{
                .nested = .{ .value = item, .depth = current.depth + 1 },
            });
        }
    }
}

fn inspectNestedLawValue(
    allocator: std.mem.Allocator,
    current: ValueDepth,
    stack: *std.ArrayList(LawUseTask),
) !void {
    if (current.depth > 64) return error.ArtifactRuleDepthExceeded;
    switch (current.value) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const child = ValueDepth{
                    .value = entry.value_ptr.*,
                    .depth = current.depth + 1,
                };
                try stack.append(allocator, if (isRuleListKey(entry.key_ptr.*))
                    .{ .laws = child }
                else
                    .{ .nested = child });
            }
        },
        .array => |array| for (array.items) |item| {
            try stack.append(allocator, .{
                .nested = .{ .value = item, .depth = current.depth + 1 },
            });
        },
        else => {},
    }
}

fn isRuleListKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "rules") or
        std.mem.eql(u8, key, "target_rules") or
        std.mem.eql(u8, key, "coverage_rules") or
        std.mem.eql(u8, key, "match_rules");
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

const structural_graph_source =
    \\{"documents":{"record":{"object":"closed","fields":{"id":{"identifier":{"max":32}},"status":{"enum":["open","closed"]},"note":{"optional":"nullable","string":{"max":128}},"required_note":{"if_present":"nullable","string":{"max":128}}}}}}
;

test "structural graph lowers to bounded native rules" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        structural_graph_source,
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

test "native rule form remains a bounded definition source" {
    const allocator = std.testing.allocator;
    var shape = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"rules":[{"op":"digest","input":"record","path":"/fingerprint"}]}
    ,
        .{ .allocate = .alloc_always },
    );
    defer shape.deinit();
    var constraints = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\[{"op":"field-equal","input":"record","left":"/a","right":"/b"}]
    ,
        .{ .allocate = .alloc_always },
    );
    defer constraints.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: ExpansionBudget = .{};
    const shape_rules = try lowerShape(
        arena.allocator(),
        shape.value,
        &.{"record"},
        &budget,
    );
    const constraint_rules = try lowerConstraints(
        arena.allocator(),
        constraints.value,
        &.{"record"},
        &budget,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        (try definition_core.json.array(shape_rules)).items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        (try definition_core.json.array(constraint_rules)).items.len,
    );
    try std.testing.expectEqual(@as(usize, 2), budget.emitted);
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
        \\{"laws":[["implies",{"input":"record","if":"/status","equals":"closed","rules":[["bounded-string",{"path":"/note","min":1}]]}]]}
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

const compact_protocol_source =
    \\{"terms":{"same-id":["cross-input-equal","#/id","prior#/id"]},"scope":{"input":"event","path":"/body"},"laws":[["use","same-id"],["reference-exists",[["#/refs",""]],[["prior#/items","/id"]],{"single":true}]],"event_log":{"start":1,"genesis":null,"kinds":["created"]},"state":{"mode":"retained","event_kind":"/kind","registers":{"current":4096},"sets":{},"admissions":[{"on":"created","forbids":["current"],"actions":[["set","current","event#/body"]]}]}}
;

test "compact terms scope protocol and retained state lower once" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        compact_protocol_source,
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

const shared_event_source =
    \\{"$event":{"slot":"events","effect":"compare-and-append","input":"request","mode":"chained","body_input":"body","request":{"schema":"example-request/v1","kind":"$kind"},"forbid":["capability"],"fields":{"event_id":["sequence","e-"],"kind":["literal","$kind"],"recorded_at":"unix-seconds"}},"capture":"created","bind":{"effect":"bind-existing","input":"existing","kind":"input","request":null,"forbid":[],"fields":{"kind":"input"}}}
;

test "shared event template lowers passive operation plans" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        shared_event_source,
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
