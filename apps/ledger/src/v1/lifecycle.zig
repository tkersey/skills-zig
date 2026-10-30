const std = @import("std");
const definition_core = @import("definition_core");
const json = definition_core.json;
const Pointer = definition_core.json_pointer.Pointer;

pub const schema = "ledger-artifact-lifecycle/v1";
pub const max_slots: usize = 256;
pub const max_references: usize = 256;
pub const max_references_per_record: usize = 4096;
pub const max_effects_per_operation: usize = 128;
pub const max_holds_per_artifact: usize = 1024;
pub const max_grace_seconds: usize = 315_576_000;

pub const Codec = enum { json, jsonl, text, bytes };
pub const SlotKind = enum { document, event_log, attachment };
pub const Slot = struct { name: []const u8, kind: SlotKind, codec: Codec };
pub const Input = struct { name: []const u8, codec: Codec, validated: bool };
pub const Declarations = struct {
    slots: []const Slot,
    inputs: []const Input,
    operations: []const []const u8,
};

pub const Retention = union(enum) { retain, until_release: u32 };
pub const SlotRule = struct { slot: []const u8, retention: Retention };
pub const Cardinality = enum { one, @"optional-one", many };
pub const Strength = enum { retain, provenance };
pub const Reference = struct {
    source_slot: []const u8,
    pointer: Pointer,
    cardinality: Cardinality,
    strength: Strength,
};
pub const Selector = struct { input: []const u8, pointer: Pointer };
pub const HoldEffect = struct { artifact: Selector, hold_id: Selector };
pub const Effect = union(enum) {
    release: Selector,
    hold: HoldEffect,
    release_hold: HoldEffect,
};
pub const Operation = struct { name: []const u8, effects: []const Effect };
pub const Bounds = struct {
    max_references_per_record: usize,
    max_effects_per_operation: usize,
    max_holds_per_artifact: usize,
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    slots: []const SlotRule,
    references: []const Reference,
    operations: []const Operation,
    bounds: Bounds,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn retentionForSlot(self: Plan, slot: []const u8) Retention {
        for (self.slots) |rule| {
            if (std.mem.eql(u8, rule.slot, slot)) return rule.retention;
        }
        return .retain;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    source: std.json.Value,
    declarations: Declarations,
) !Plan {
    const root = try json.object(source);
    const keys = &.{ "schema", "slots", "references", "operations", "bounds" };
    try json.requireExactKeys(root, keys);
    try json.requireFields(root, keys);
    if (!std.mem.eql(u8, try json.requiredString(root, "schema"), schema)) {
        return error.UnsupportedLifecycleSchema;
    }
    const bounds = try compileBounds(try json.field(root, "bounds"));
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const slots = try compileSlots(owned, try json.field(root, "slots"), declarations);
    const references = try compileReferences(
        owned,
        try json.field(root, "references"),
        declarations,
    );
    const operations = try compileOperations(
        owned,
        try json.field(root, "operations"),
        declarations,
        bounds,
    );
    return .{
        .arena = arena,
        .slots = slots,
        .references = references,
        .operations = operations,
        .bounds = bounds,
    };
}

fn compileBounds(raw: std.json.Value) !Bounds {
    const map = try json.object(raw);
    const keys = &.{
        "max_references_per_record", "max_effects_per_operation", "max_holds_per_artifact",
    };
    try json.requireExactKeys(map, keys);
    try json.requireFields(map, keys);
    return .{
        .max_references_per_record = try bounded(
            try json.field(map, "max_references_per_record"),
            max_references_per_record,
        ),
        .max_effects_per_operation = try bounded(
            try json.field(map, "max_effects_per_operation"),
            max_effects_per_operation,
        ),
        .max_holds_per_artifact = try bounded(
            try json.field(map, "max_holds_per_artifact"),
            max_holds_per_artifact,
        ),
    };
}

fn bounded(raw: std.json.Value, maximum: usize) !usize {
    const number = try json.unsigned(raw);
    if (number > maximum) return error.LifecycleBoundExceeded;
    return number;
}

fn declaredSlot(declarations: Declarations, name: []const u8) !Slot {
    for (declarations.slots) |slot| {
        if (!std.mem.eql(u8, slot.name, name)) continue;
        const valid = switch (slot.kind) {
            .document => slot.codec == .json or slot.codec == .text,
            .event_log => slot.codec == .jsonl,
            .attachment => slot.codec == .bytes,
        };
        if (!valid) return error.InvalidLifecycleSlotCodec;
        return slot;
    }
    return error.UnknownLifecycleSlot;
}

fn compileSlots(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    declarations: Declarations,
) ![]const SlotRule {
    const map = try json.object(raw);
    if (map.count() > max_slots) return error.TooManyLifecycleSlots;
    const slots = try allocator.alloc(SlotRule, map.count());
    var iterator = map.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        const slot = try declaredSlot(declarations, entry.key_ptr.*);
        const rule = try json.object(entry.value_ptr.*);
        try json.requireExactKeys(rule, &.{"retention"});
        const retention = try json.object(try json.field(rule, "retention"));
        const kind = try json.requiredString(retention, "kind");
        const compiled: Retention = if (std.mem.eql(u8, kind, "retain")) retain: {
            try json.requireExactKeys(retention, &.{"kind"});
            break :retain .retain;
        } else if (std.mem.eql(u8, kind, "until-release")) release: {
            try json.requireExactKeys(retention, &.{ "kind", "grace_seconds" });
            if (slot.kind != .attachment) return error.UnsupportedLifecycleRetention;
            const grace = try bounded(
                try json.field(retention, "grace_seconds"),
                max_grace_seconds,
            );
            break :release .{ .until_release = @intCast(grace) };
        } else return error.UnsupportedLifecycleRetention;
        slots[index] = .{
            .slot = try allocator.dupe(u8, entry.key_ptr.*),
            .retention = compiled,
        };
    }
    return slots;
}

fn compileReferences(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    declarations: Declarations,
) ![]const Reference {
    const array = try json.array(raw);
    if (array.items.len > max_references) return error.TooManyLifecycleReferences;
    const references = try allocator.alloc(Reference, array.items.len);
    for (array.items, references) |item, *reference| {
        const map = try json.object(item);
        const keys = &.{ "source_slot", "pointer", "cardinality", "strength" };
        try json.requireExactKeys(map, keys);
        try json.requireFields(map, keys);
        const name = try json.requiredString(map, "source_slot");
        const slot = try declaredSlot(declarations, name);
        if (slot.kind == .attachment or slot.codec == .text) {
            return error.UnsupportedLifecycleReferenceSource;
        }
        const cardinality = try json.requiredString(map, "cardinality");
        const strength = try json.requiredString(map, "strength");
        reference.* = .{
            .source_slot = try allocator.dupe(u8, name),
            .pointer = try definition_core.json_pointer.compile(
                allocator,
                try json.string(try json.field(map, "pointer")),
            ),
            .cardinality = std.meta.stringToEnum(Cardinality, cardinality) orelse
                return error.UnsupportedLifecycleCardinality,
            .strength = std.meta.stringToEnum(Strength, strength) orelse
                return error.UnsupportedLifecycleStrength,
        };
    }
    return references;
}

fn compileOperations(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    declarations: Declarations,
    bounds: Bounds,
) ![]const Operation {
    const map = try json.object(raw);
    if (map.count() > declarations.operations.len) return error.UnknownLifecycleOperation;
    const operations = try allocator.alloc(Operation, map.count());
    var iterator = map.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        var found = false;
        for (declarations.operations) |name| {
            if (std.mem.eql(u8, name, entry.key_ptr.*)) found = true;
        }
        if (!found) return error.UnknownLifecycleOperation;
        const array = try json.array(entry.value_ptr.*);
        if (array.items.len > bounds.max_effects_per_operation) {
            return error.TooManyLifecycleEffects;
        }
        const effects = try allocator.alloc(Effect, array.items.len);
        for (array.items, effects) |item, *effect| {
            effect.* = try compileEffect(allocator, item, declarations);
        }
        operations[index] = .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .effects = effects,
        };
    }
    return operations;
}

fn compileEffect(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    declarations: Declarations,
) !Effect {
    const map = try json.object(raw);
    const op = try json.requiredString(map, "op");
    if (std.mem.eql(u8, op, "release")) {
        try json.requireExactKeys(map, &.{ "op", "artifact" });
        return .{ .release = try compileSelector(
            allocator,
            try json.field(map, "artifact"),
            declarations,
        ) };
    }
    const hold = std.mem.eql(u8, op, "hold");
    if (!hold and !std.mem.eql(u8, op, "release-hold")) return error.UnsupportedLifecycleEffect;
    try json.requireExactKeys(map, &.{ "op", "artifact", "hold_id" });
    const effect: HoldEffect = .{
        .artifact = try compileSelector(allocator, try json.field(map, "artifact"), declarations),
        .hold_id = try compileSelector(allocator, try json.field(map, "hold_id"), declarations),
    };
    return if (hold) .{ .hold = effect } else .{ .release_hold = effect };
}

fn compileSelector(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    declarations: Declarations,
) !Selector {
    const map = try json.object(raw);
    try json.requireExactKeys(map, &.{ "input", "pointer" });
    const input = try json.requiredString(map, "input");
    var found = false;
    for (declarations.inputs) |candidate| {
        if (!std.mem.eql(u8, candidate.name, input)) continue;
        if (candidate.codec != .json or !candidate.validated) return error.InvalidLifecycleInput;
        found = true;
    }
    if (!found) return error.UnknownLifecycleInput;
    return .{
        .input = try allocator.dupe(u8, input),
        .pointer = try definition_core.json_pointer.compile(
            allocator,
            try json.string(try json.field(map, "pointer")),
        ),
    };
}

const fixture =
    \\{"schema":"ledger-artifact-lifecycle/v1","slots":{
    \\"events":{"retention":{"kind":"retain"}},
    \\"attachments":{"retention":{"kind":"until-release","grace_seconds":604800}}},
    \\"references":[{"source_slot":"events","pointer":"/attachment",
    \\"cardinality":"optional-one","strength":"provenance"}],"operations":{
    \\"finish":[{"op":"release","artifact":{"input":"submission","pointer":"/attachment"}}],
    \\"pin":[{"op":"hold","artifact":{"input":"submission","pointer":"/attachment"},
    \\"hold_id":{"input":"submission","pointer":"/hold_id"}}],
    \\"unpin":[{"op":"release-hold","artifact":{"input":"submission","pointer":"/attachment"},
    \\"hold_id":{"input":"submission","pointer":"/hold_id"}}]},"bounds":{
    \\"max_references_per_record":64,"max_effects_per_operation":16,"max_holds_per_artifact":64}}
;

const declared: Declarations = .{
    .slots = &.{
        .{ .name = "events", .kind = .event_log, .codec = .jsonl },
        .{ .name = "documents", .kind = .document, .codec = .json },
        .{ .name = "attachments", .kind = .attachment, .codec = .bytes },
    },
    .inputs = &.{.{ .name = "submission", .codec = .json, .validated = true }},
    .operations = &.{ "finish", "pin", "unpin" },
};

fn compileFixture(allocator: std.mem.Allocator, bytes: []const u8, context: Declarations) !Plan {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
    defer parsed.deinit();
    return compile(allocator, parsed.value, context);
}

fn expectMutation(before: []const u8, after: []const u8, expected: ?anyerror) !void {
    const allocator = std.testing.allocator;
    const bytes = try std.mem.replaceOwned(u8, allocator, fixture, before, after);
    defer allocator.free(bytes);
    if (expected) |err| {
        try std.testing.expectError(err, compileFixture(allocator, bytes, declared));
    } else {
        var plan = try compileFixture(allocator, bytes, declared);
        defer plan.deinit();
    }
}

test "lifecycle compiles owned retention references and effects with conservative defaults" {
    var plan = try compileFixture(std.testing.allocator, fixture, declared);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.slots.len);
    try std.testing.expectEqual(
        @as(u32, 604800),
        plan.retentionForSlot("attachments").until_release,
    );
    try std.testing.expect(plan.retentionForSlot("documents") == .retain);
    try std.testing.expectEqual(Cardinality.@"optional-one", plan.references[0].cardinality);
    try std.testing.expectEqual(Strength.provenance, plan.references[0].strength);
    try std.testing.expectEqualStrings("attachment", plan.references[0].pointer.segments[0]);
    try std.testing.expectEqualStrings("submission", plan.operations[0].effects[0].release.input);
    try std.testing.expectEqualStrings(
        "hold_id",
        plan.operations[1].effects[0].hold.hold_id.pointer.segments[0],
    );
    try std.testing.expect(plan.operations[2].effects[0] == .release_hold);
}

test "lifecycle closed grammar rejects missing unknown duplicate and incorrect values" {
    try expectMutation("\"schema\":", "\"extra\":0,\"schema\":", error.UnknownField);
    try expectMutation("\"retention\":", "\"extra\":0,\"retention\":", error.UnknownField);
    try expectMutation("\"source_slot\":", "\"extra\":0,\"source_slot\":", error.UnknownField);
    try expectMutation("\"input\":", "\"parameter\":", error.UnknownField);
    try expectMutation("\"max_holds_per_artifact\":64", "\"other\":64", error.UnknownField);
    try expectMutation("\"schema\":", "\"schema\":\"duplicate\",\"schema\":", error.DuplicateField);
    try expectMutation("\"grace_seconds\":604800", "", error.SyntaxError);
    try expectMutation(
        ",\"grace_seconds\":604800",
        "",
        error.MissingField,
    );
    try expectMutation("\"pointer\":\"/hold_id\"", "\"pointer\":false", error.ExpectedString);
    try expectMutation(
        "ledger-artifact-lifecycle/v1",
        "ledger-artifact-lifecycle/v2",
        error.UnsupportedLifecycleSchema,
    );
    try expectMutation("optional-one", "optional", error.UnsupportedLifecycleCardinality);
    try expectMutation("provenance", "weak", error.UnsupportedLifecycleStrength);
    try expectMutation("release-hold", "delete", error.UnsupportedLifecycleEffect);
    try expectMutation("/hold_id", "/~2", error.InvalidJsonPointer);
}

test "lifecycle validates declaration compositions and valid JSON Pointer neighbors" {
    try expectMutation("\"attachments\":", "\"events\":", error.DuplicateField);
    try expectMutation("\"attachments\":", "\"documents\":", error.UnsupportedLifecycleRetention);
    try expectMutation("\"attachments\":", "\"unknown\":", error.UnknownLifecycleSlot);
    try expectMutation(
        "\"source_slot\":\"events\"",
        "\"source_slot\":\"attachments\"",
        error.UnsupportedLifecycleReferenceSource,
    );
    try expectMutation("\"finish\":", "\"unknown\":", error.UnknownLifecycleOperation);
    try expectMutation(
        "\"input\":\"submission\"",
        "\"input\":\"unknown\"",
        error.UnknownLifecycleInput,
    );
    try expectMutation("\"source_slot\":\"events\"", "\"source_slot\":\"documents\"", null);
    try expectMutation("optional-one", "one", null);
    try expectMutation("optional-one", "many", null);
    try expectMutation("provenance", "retain", null);
    try expectMutation("/hold_id", "", null);
    try expectMutation("/hold_id", "/a~1b/~0/*", null);
    var context = declared;
    context.inputs = &.{.{ .name = "submission", .codec = .bytes, .validated = true }};
    try std.testing.expectError(
        error.InvalidLifecycleInput,
        compileFixture(std.testing.allocator, fixture, context),
    );
    context.inputs = &.{.{ .name = "submission", .codec = .json, .validated = false }};
    try std.testing.expectError(
        error.InvalidLifecycleInput,
        compileFixture(std.testing.allocator, fixture, context),
    );
    context = declared;
    context.slots = &.{.{ .name = "events", .kind = .event_log, .codec = .bytes }};
    try std.testing.expectError(
        error.InvalidLifecycleSlotCodec,
        compileFixture(std.testing.allocator, fixture, context),
    );
}

test "lifecycle exact integer bounds accept maxima and reject overflow and fractions" {
    try expectMutation("604800", "315576000", null);
    try expectMutation("604800", "315576001", error.LifecycleBoundExceeded);
    try expectMutation("604800", "0", null);
    try expectMutation("604800", "3.15576e8", null);
    try expectMutation("604800", "-1", error.ExpectedUnsigned);
    try expectMutation("604800", "1.5", error.ExpectedInteger);
    try expectMutation("604800", "18446744073709551616", error.ExpectedInteger);
    try expectMutation("604800", "1e100000", error.ExpectedInteger);
    try expectMutation("604800", "\"604800\"", error.ExpectedInteger);
    try expectMutation(
        "\"max_references_per_record\":64",
        "\"max_references_per_record\":4096",
        null,
    );
    try expectMutation(
        "\"max_references_per_record\":64",
        "\"max_references_per_record\":4097",
        error.LifecycleBoundExceeded,
    );
    try expectMutation(
        "\"max_effects_per_operation\":16",
        "\"max_effects_per_operation\":128",
        null,
    );
    try expectMutation(
        "\"max_effects_per_operation\":16",
        "\"max_effects_per_operation\":129",
        error.LifecycleBoundExceeded,
    );
    try expectMutation("\"max_holds_per_artifact\":64", "\"max_holds_per_artifact\":1024", null);
    try expectMutation(
        "\"max_holds_per_artifact\":64",
        "\"max_holds_per_artifact\":1025",
        error.LifecycleBoundExceeded,
    );
    try expectMutation(
        "\"max_effects_per_operation\":16",
        "\"max_effects_per_operation\":0",
        error.TooManyLifecycleEffects,
    );
    try expectMutation("\"max_references_per_record\":64", "\"max_references_per_record\":0", null);
    try expectMutation("\"max_holds_per_artifact\":64", "\"max_holds_per_artifact\":0", null);
}

fn structuralBoundary(slot_count: usize, reference_count: usize, effect_count: usize) !void {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, fixture, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    const root = &parsed.value.object;
    const raw_slots = &root.getPtr("slots").?.object;
    const retain = raw_slots.get("events").?;
    raw_slots.clearRetainingCapacity();
    const slots = try arena.alloc(Slot, slot_count);
    for (slots, 0..) |*slot, index| {
        const name = if (index == 0)
            "events"
        else
            try std.fmt.allocPrint(arena, "slot-{d}", .{index});
        slot.* = .{ .name = name, .kind = .event_log, .codec = .jsonl };
        try raw_slots.put(arena, name, retain);
    }
    const references = &root.getPtr("references").?.array;
    const reference = references.items[0];
    references.clearRetainingCapacity();
    for (0..reference_count) |_| try references.append(reference);
    const operations = &root.getPtr("operations").?.object;
    const effect = operations.get("finish").?.array.items[0];
    operations.clearRetainingCapacity();
    var effects = std.json.Array.init(arena);
    for (0..effect_count) |_| try effects.append(effect);
    try operations.put(arena, "finish", .{ .array = effects });
    root.getPtr("bounds").?.object.getPtr("max_effects_per_operation").?.* = .{
        .integer = max_effects_per_operation,
    };
    var context = declared;
    context.slots = slots;
    var plan = try compile(allocator, parsed.value, context);
    defer plan.deinit();
    try std.testing.expectEqual(slot_count, plan.slots.len);
    try std.testing.expectEqual(reference_count, plan.references.len);
    try std.testing.expectEqual(effect_count, plan.operations[0].effects.len);
}

test "lifecycle structural declarations and effects accept exact maxima" {
    try structuralBoundary(max_slots, max_references, max_effects_per_operation);
    try structuralBoundary(0, 0, 0);
    try std.testing.expectError(
        error.TooManyLifecycleSlots,
        structuralBoundary(max_slots + 1, 1, 1),
    );
    try std.testing.expectError(
        error.TooManyLifecycleReferences,
        structuralBoundary(1, max_references + 1, 1),
    );
    try std.testing.expectError(
        error.TooManyLifecycleEffects,
        structuralBoundary(1, 1, max_effects_per_operation + 1),
    );
}

test "lifecycle retains existing text documents but rejects reference extraction from text" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, fixture, .{
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    const root = &parsed.value.object;
    const slots = &root.getPtr("slots").?.object;
    try slots.put(arena, "documents", slots.get("events").?);
    var context = declared;
    var declared_slots = [_]Slot{ declared.slots[0], declared.slots[1], declared.slots[2] };
    declared_slots[1].codec = .text;
    context.slots = &declared_slots;
    var plan = try compile(allocator, parsed.value, context);
    defer plan.deinit();
    try std.testing.expect(plan.retentionForSlot("documents") == .retain);
    root.getPtr("references").?.array.items[0].object.getPtr("source_slot").?.* = .{
        .string = "documents",
    };
    try std.testing.expectError(
        error.UnsupportedLifecycleReferenceSource,
        compile(allocator, parsed.value, context),
    );
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var plan = try compileFixture(allocator, fixture, declared);
    defer plan.deinit();
}

test "lifecycle compiler releases partial owned plans after allocation failure" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        allocationProbe,
        .{},
    );
}
