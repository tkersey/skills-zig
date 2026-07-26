const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const definition = @import("definition.zig");
const execution = @import("execution.zig");
const observation_plan = @import("plan.zig");

const max_external_cells: usize = 4_000_000;

pub const Relation = struct {
    input_index: u16,
    parsed: std.json.Parsed(std.json.Value),
    values: []execution.Value,
    canonical_json_values: [][]u8,
    row_count: usize,
    width: usize,
    raw_digest: [71]u8,

    pub fn deinit(self: *Relation, allocator: std.mem.Allocator) void {
        for (self.canonical_json_values) |value| allocator.free(value);
        allocator.free(self.canonical_json_values);
        allocator.free(self.values);
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn rows(self: *const Relation) execution.Rows {
        return .{ .values = self.values, .width = self.width };
    }
};

pub fn loadFile(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    input_name: []const u8,
    path: []const u8,
) !Relation {
    const input = findInput(definition_plan.inputs, input_name) orelse
        return error.UnknownExternalInput;
    const max_bytes = @min(
        input.value.max_bytes,
        definition_plan.bounds.max_input_bytes,
    );
    const bytes = try durable_store.readRegularFileNoSymlink(
        allocator,
        path,
        max_bytes,
    );
    defer allocator.free(bytes);
    return parseBytes(
        allocator,
        definition_plan,
        input_name,
        bytes,
    );
}

pub fn parseBytes(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    input_name: []const u8,
    bytes: []const u8,
) !Relation {
    const found = findInput(definition_plan.inputs, input_name) orelse
        return error.UnknownExternalInput;
    const input = found.value;
    if (bytes.len > input.max_bytes or
        bytes.len > definition_plan.bounds.max_input_bytes)
    {
        return error.ExternalInputBytesExceeded;
    }
    const raw_digest = digestBytes(bytes);
    if (input.digest) |expected| {
        if (!std.mem.eql(u8, expected, &raw_digest)) {
            return error.ExternalInputDigestMismatch;
        }
    }

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.DuplicateField => return error.DuplicateExternalInputField,
        else => return error.InvalidExternalInputJson,
    };
    errdefer parsed.deinit();
    const envelope = try definition_core.json.object(parsed.value);
    try definition_core.json.requireExactKeys(
        envelope,
        &.{ "schema", "rows" },
    );
    try definition_core.json.requireFields(
        envelope,
        &.{ "schema", "rows" },
    );
    if (!std.mem.eql(
        u8,
        try definition_core.json.requiredString(envelope, "schema"),
        input.schema_id,
    )) return error.ExternalInputSchemaMismatch;
    const rows = try definition_core.json.array(
        try definition_core.json.field(envelope, "rows"),
    );
    if (rows.items.len > input.max_rows) {
        return error.ExternalInputRowBoundExceeded;
    }
    const cell_count = std.math.mul(
        usize,
        rows.items.len,
        input.fields.len,
    ) catch return error.ExternalInputCellBoundExceeded;
    if (cell_count > max_external_cells) {
        return error.ExternalInputCellBoundExceeded;
    }
    const values = try allocator.alloc(execution.Value, cell_count);
    errdefer allocator.free(values);
    var canonical_json_values: std.ArrayList([]u8) = .empty;
    errdefer {
        for (canonical_json_values.items) |value| allocator.free(value);
        canonical_json_values.deinit(allocator);
    }

    for (rows.items, 0..) |row_value, row_index| {
        const row = try definition_core.json.object(row_value);
        try validateRowKeys(row, input.fields);
        const start = row_index * input.fields.len;
        for (input.fields, 0..) |field, field_index| {
            const value = row.get(field.name) orelse
                return error.ExternalInputFieldMissing;
            values[start + field_index] = try convertValue(
                allocator,
                field,
                value,
                &canonical_json_values,
            );
        }
    }
    const owned_json_values =
        try canonical_json_values.toOwnedSlice(allocator);
    errdefer {
        for (owned_json_values) |value| allocator.free(value);
        allocator.free(owned_json_values);
    }
    return .{
        .input_index = found.index,
        .parsed = parsed,
        .values = values,
        .canonical_json_values = owned_json_values,
        .row_count = rows.items.len,
        .width = input.fields.len,
        .raw_digest = raw_digest,
    };
}

pub fn execute(
    program: *const execution.Program,
    relation: *const Relation,
    output: []execution.Value,
) !execution.Result {
    switch (program.source) {
        .external => |index| if (index != relation.input_index) {
            return error.ExternalInputProgramMismatch;
        },
        .physical => return error.ExternalInputProgramMismatch,
    }
    return execution.execute(program, relation.rows(), output);
}

fn validateRowKeys(
    row: std.json.ObjectMap,
    fields: []const definition.ExternalField,
) !void {
    if (row.count() != fields.len) return error.ExternalInputFieldSetMismatch;
    var iterator = row.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (fields) |field| {
            if (std.mem.eql(u8, field.name, entry.key_ptr.*)) {
                found = true;
                break;
            }
        }
        if (!found) return error.ExternalInputFieldSetMismatch;
    }
}

fn convertValue(
    allocator: std.mem.Allocator,
    field: definition.ExternalField,
    value: std.json.Value,
    canonical_json_values: *std.ArrayList([]u8),
) !execution.Value {
    if (value == .null) {
        if (!field.nullable) return error.ExternalInputNullNotAllowed;
        return .null;
    }
    return switch (field.kind) {
        .string => switch (value) {
            .string => |text| .{ .string = text },
            else => error.ExternalInputFieldTypeMismatch,
        },
        .integer => switch (value) {
            .integer => |number| .{ .integer = number },
            else => error.ExternalInputFieldTypeMismatch,
        },
        .float => switch (value) {
            .integer => |number| .{
                .float = @floatFromInt(number),
            },
            .float => |number| if (std.math.isFinite(number))
                .{ .float = number }
            else
                error.ExternalInputFieldTypeMismatch,
            else => error.ExternalInputFieldTypeMismatch,
        },
        .boolean => switch (value) {
            .bool => |flag| .{ .boolean = flag },
            else => error.ExternalInputFieldTypeMismatch,
        },
        .json => json: {
            const canonical = definition_core.canonical_json
                .canonicalJsonAlloc(allocator, value) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            errdefer allocator.free(canonical);
            try canonical_json_values.append(allocator, canonical);
            break :json .{ .json = canonical };
        },
    };
}

const InputRef = struct {
    index: u16,
    value: definition.ExternalInput,
};

fn findInput(
    inputs: []const definition.ExternalInput,
    name: []const u8,
) ?InputRef {
    for (inputs, 0..) |input, index| {
        if (std.mem.eql(u8, input.name, name)) {
            return .{ .index = @intCast(index), .value = input };
        }
    }
    return null;
}

fn digestBytes(bytes: []const u8) [71]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    const hex = std.fmt.bytesToHex(raw, .lower);
    var digest: [71]u8 = undefined;
    @memcpy(digest[0..7], "sha256:");
    @memcpy(digest[7..], &hex);
    return digest;
}

fn parseForAllocationFailure(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    bytes: []const u8,
) !void {
    var relation = parseBytes(
        allocator,
        definition_plan,
        "facts",
        bytes,
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer relation.deinit(allocator);
}

test "external immutable relations validate schema fields and canonical json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/external-input","requires":{"abi":"seq-observation-abi/v1","operators":["project"]},"parameters":{},"selectors":[],"relations":[],"inputs":[{"name":"facts","schema":"example-facts/v1","fields":[{"name":"id","type":"string","nullable":false},{"name":"count","type":"integer","nullable":false},{"name":"score","type":"float","nullable":false},{"name":"active","type":"boolean","nullable":false},{"name":"detail","type":"json","nullable":true}],"max_rows":10,"max_bytes":4096}],"pipeline":[{"op":"project","input":"facts","as":"rows","fields":["id","count","score","active","detail"]}],"projections":{"rows":{"relation":"rows","schema":"example-rows/v1","fields":["id","count","score","active","detail"],"renderers":["json"]}},"bounds":{"max_rows":10,"max_output_bytes":4096,"max_fold_states":2,"max_input_bytes":4096}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "observation.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "observation.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    const input =
        \\{"schema":"example-facts/v1","rows":[{"id":"a","count":2,"score":1.5,"active":true,"detail":{"z":1,"a":2}},{"id":"b","count":3,"score":2,"active":false,"detail":null}]}
    ;
    var relation = try parseBytes(
        std.testing.allocator,
        &definition_plan,
        "facts",
        input,
    );
    defer relation.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), relation.row_count);
    try std.testing.expectEqual(@as(usize, 5), relation.width);
    try std.testing.expectEqualStrings(
        "a",
        relation.rows().row(0)[0].string,
    );
    try std.testing.expectEqual(@as(i64, 2), relation.rows().row(0)[1].integer);
    try std.testing.expectEqual(@as(f64, 2), relation.rows().row(1)[2].float);
    try std.testing.expectEqualStrings(
        "{\"a\":2,\"z\":1}",
        relation.rows().row(0)[4].json,
    );
    try std.testing.expect(relation.rows().row(1)[4] == .null);
    var native_plan = try observation_plan.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer native_plan.deinit(std.testing.allocator);
    var bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{},
    );
    defer bindings.deinit(std.testing.allocator);
    var program = try execution.compile(
        std.testing.allocator,
        &definition_plan,
        &native_plan,
        &bindings,
        "rows",
    );
    defer program.deinit(std.testing.allocator);
    var output: [10]execution.Value = undefined;
    const result = try execute(&program, &relation, &output);
    try std.testing.expectEqual(@as(usize, 2), result.row_count);
    try std.testing.expectEqualStrings(
        "b",
        result.rows().row(1)[0].string,
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseForAllocationFailure,
        .{ &definition_plan, input },
    );
}

test "external immutable relations fail closed on shape type and digest drift" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/external-errors","requires":{"abi":"seq-observation-abi/v1","operators":["project"]},"parameters":{},"selectors":[],"relations":[],"inputs":[{"name":"facts","schema":"example-facts/v1","fields":[{"name":"id","type":"string","nullable":false}],"max_rows":1,"max_bytes":1024}],"pipeline":[{"op":"project","input":"facts","as":"rows","fields":["id"]}],"projections":{"rows":{"relation":"rows","schema":"example-rows/v1","fields":["id"],"renderers":["json"]}},"bounds":{"max_rows":1,"max_output_bytes":1024,"max_fold_states":1,"max_input_bytes":1024}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "observation.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "observation.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ExternalInputSchemaMismatch,
        parseBytes(
            std.testing.allocator,
            &definition_plan,
            "facts",
            \\{"schema":"wrong/v1","rows":[{"id":"a"}]}
            ,
        ),
    );
    try std.testing.expectError(
        error.ExternalInputFieldSetMismatch,
        parseBytes(
            std.testing.allocator,
            &definition_plan,
            "facts",
            \\{"schema":"example-facts/v1","rows":[{"id":"a","extra":1}]}
            ,
        ),
    );
    try std.testing.expectError(
        error.ExternalInputFieldTypeMismatch,
        parseBytes(
            std.testing.allocator,
            &definition_plan,
            "facts",
            \\{"schema":"example-facts/v1","rows":[{"id":1}]}
            ,
        ),
    );
    try std.testing.expectError(
        error.ExternalInputRowBoundExceeded,
        parseBytes(
            std.testing.allocator,
            &definition_plan,
            "facts",
            \\{"schema":"example-facts/v1","rows":[{"id":"a"},{"id":"b"}]}
            ,
        ),
    );

    definition_plan.inputs[0].digest = try std.testing.allocator.dupe(
        u8,
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    );
    try std.testing.expectError(
        error.ExternalInputDigestMismatch,
        parseBytes(
            std.testing.allocator,
            &definition_plan,
            "facts",
            \\{"schema":"example-facts/v1","rows":[{"id":"a"}]}
            ,
        ),
    );
}
