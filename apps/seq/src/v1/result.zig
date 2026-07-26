const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const execution = @import("execution.zig");

pub const schema = "seq-observation-result/v1";

pub const Corpus = struct {
    adapter: []const u8,
    digest: []const u8,
    files: usize,
    sessions: usize,
    contaminated: bool,
};

pub const Envelope = struct {
    definition_plan: *const definition.Plan,
    projection_name: []const u8,
    parameters_digest: []const u8,
    corpus: Corpus,
    rows: execution.Rows,
    compile_stats: definition_core.result.CompileStats,
    execution_stats: definition_core.result.ExecutionStats,
    limitations: []const []const u8 = &.{},
};

pub fn renderJsonAlloc(
    allocator: std.mem.Allocator,
    envelope: Envelope,
) ![]u8 {
    try validateEnvelope(envelope);
    const projection = findProjection(
        envelope.definition_plan.projections,
        envelope.projection_name,
    ).?;
    var output = BoundedJson.init(
        allocator,
        envelope.definition_plan.bounds.max_output_bytes,
    );
    errdefer output.deinit();

    try output.raw("{\"schema\":");
    try output.string(schema);
    try output.raw(",\"definition\":{\"id\":");
    try output.string(envelope.definition_plan.id);
    try output.raw(",\"digest\":");
    try output.string(&envelope.definition_plan.closure_digest);
    try output.raw(",\"abi\":");
    try output.string(definition.abi);
    try output.raw("},\"corpus\":{\"adapter\":");
    try output.string(envelope.corpus.adapter);
    try output.raw(",\"digest\":");
    try output.string(envelope.corpus.digest);
    try output.raw(",\"files\":");
    try output.usizeValue(envelope.corpus.files);
    try output.raw(",\"sessions\":");
    try output.usizeValue(envelope.corpus.sessions);
    try output.raw(",\"contaminated\":");
    try output.boolean(envelope.corpus.contaminated);
    try output.raw("},\"parameters_digest\":");
    try output.string(envelope.parameters_digest);
    try output.raw(",\"projection\":");
    try output.string(envelope.projection_name);
    try output.raw(",\"data\":{\"schema\":");
    try output.string(projection.schema_id);
    try output.raw(",\"rows\":[");
    const row_count = try envelope.rows.count();
    for (0..row_count) |row_index| {
        if (row_index != 0) try output.raw(",");
        try output.raw("{");
        const row = envelope.rows.row(row_index);
        for (projection.fields, 0..) |field, field_index| {
            if (field_index != 0) try output.raw(",");
            try output.string(field);
            try output.raw(":");
            try output.writeValue(row[field_index]);
        }
        try output.raw("}");
    }
    try output.raw("]},\"stats\":{\"cache_hit\":");
    try output.boolean(envelope.compile_stats.cache_hit);
    try output.raw(",\"cache_write_failed\":");
    try output.boolean(envelope.compile_stats.cache_write_failed);
    try output.raw(",\"compile_ns\":");
    try output.u64Value(envelope.compile_stats.compile_ns);
    try output.raw(",\"closure_files\":");
    try output.usizeValue(envelope.compile_stats.closure_files);
    try output.raw(",\"closure_bytes\":");
    try output.usizeValue(envelope.compile_stats.closure_bytes);
    try output.raw(",\"execution_ns\":");
    try output.u64Value(envelope.execution_stats.execution_ns);
    try output.raw(",\"physical_passes\":");
    try output.usizeValue(envelope.execution_stats.physical_passes);
    try output.raw(",\"files_opened\":");
    try output.usizeValue(envelope.execution_stats.files_opened);
    try output.raw(",\"bytes_read\":");
    try output.usizeValue(envelope.execution_stats.bytes_read);
    try output.raw(",\"rows_scanned\":");
    try output.usizeValue(envelope.execution_stats.rows_scanned);
    try output.raw(",\"rows_materialized\":");
    try output.usizeValue(envelope.execution_stats.rows_materialized);
    try output.raw(",\"output_rows\":");
    try output.usizeValue(envelope.execution_stats.output_rows);
    try output.raw(",\"output_bytes\":");
    try output.usizeValue(envelope.execution_stats.output_bytes);
    try output.raw("},\"limitations\":[");
    for (envelope.limitations, 0..) |limitation, index| {
        if (index != 0) try output.raw(",");
        try output.string(limitation);
    }
    try output.raw("],\"authority_granted\":false}");
    return output.toOwnedSlice();
}

fn validateEnvelope(envelope: Envelope) !void {
    const projection = findProjection(
        envelope.definition_plan.projections,
        envelope.projection_name,
    ) orelse return error.UnknownObservationProjection;
    try definition_core.json.digest(envelope.parameters_digest);
    try definition_core.json.digest(envelope.corpus.digest);
    if (envelope.corpus.adapter.len == 0 or
        envelope.corpus.adapter.len > 128 or
        !std.unicode.utf8ValidateSlice(envelope.corpus.adapter))
    {
        return error.InvalidCorpusAdapter;
    }
    if (envelope.rows.width != projection.fields.len) {
        return error.ObservationResultWidthMismatch;
    }
    const row_count = try envelope.rows.count();
    if (row_count > envelope.definition_plan.bounds.max_rows) {
        return error.ObservationRowBoundExceeded;
    }
    if (envelope.execution_stats.output_rows != row_count) {
        return error.ObservationResultStatsMismatch;
    }
    if (envelope.limitations.len >
        envelope.definition_plan.bounds.max_diagnostics)
    {
        return error.ObservationLimitationsBoundExceeded;
    }
    for (envelope.limitations) |limitation| {
        if (!std.unicode.utf8ValidateSlice(limitation)) {
            return error.InvalidObservationLimitation;
        }
    }
}

fn findProjection(
    projections: []const definition.Projection,
    name: []const u8,
) ?*const definition.Projection {
    for (projections) |*projection| {
        if (std.mem.eql(u8, projection.name, name)) return projection;
    }
    return null;
}

const BoundedJson = struct {
    allocator: std.mem.Allocator,
    output: std.Io.Writer.Allocating,
    max_bytes: usize,

    fn init(allocator: std.mem.Allocator, max_bytes: usize) BoundedJson {
        return .{
            .allocator = allocator,
            .output = .init(allocator),
            .max_bytes = max_bytes,
        };
    }

    fn deinit(self: *BoundedJson) void {
        self.output.deinit();
        self.* = undefined;
    }

    fn toOwnedSlice(self: *BoundedJson) ![]u8 {
        return self.output.toOwnedSlice();
    }

    fn raw(self: *BoundedJson, bytes: []const u8) !void {
        try self.ensure(bytes.len);
        self.output.writer.writeAll(bytes) catch return error.OutOfMemory;
    }

    fn string(self: *BoundedJson, value: []const u8) !void {
        const encoded_length = try canonicalStringLength(value);
        try self.ensure(encoded_length);
        definition_core.canonical_json.writeCanonicalString(
            &self.output.writer,
            value,
        ) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
    }

    fn boolean(self: *BoundedJson, value: bool) !void {
        try self.raw(if (value) "true" else "false");
    }

    fn usizeValue(self: *BoundedJson, value: usize) !void {
        var buffer: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print("{d}", .{value}) catch return error.IntegerFormatFailed;
        try self.raw(writer.buffered());
    }

    fn u64Value(self: *BoundedJson, value: u64) !void {
        var buffer: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print("{d}", .{value}) catch return error.IntegerFormatFailed;
        try self.raw(writer.buffered());
    }

    fn writeValue(self: *BoundedJson, item: execution.Value) !void {
        switch (item) {
            .string => |text| try self.string(text),
            .integer => |number| {
                var buffer: [32]u8 = undefined;
                var writer = std.Io.Writer.fixed(&buffer);
                writer.print("{d}", .{number}) catch
                    return error.IntegerFormatFailed;
                try self.raw(writer.buffered());
            },
            .float => |number| {
                var buffer: [64]u8 = undefined;
                var writer = std.Io.Writer.fixed(&buffer);
                definition_core.canonical_json.writeCanonicalFloat(
                    &writer,
                    number,
                ) catch |err| switch (err) {
                    error.WriteFailed => return error.FloatFormatFailed,
                    else => return err,
                };
                try self.raw(writer.buffered());
            },
            .boolean => |flag| try self.boolean(flag),
            .json => |raw_json| try self.jsonValue(raw_json),
            .null => try self.raw("null"),
        }
    }

    fn jsonValue(self: *BoundedJson, raw_json: []const u8) !void {
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            raw_json,
            .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
            },
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidObservationJsonValue,
        };
        defer parsed.deinit();
        const canonical = definition_core.canonical_json.canonicalJsonAlloc(
            self.allocator,
            parsed.value,
        ) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        defer self.allocator.free(canonical);
        try self.raw(canonical);
    }

    fn ensure(self: *BoundedJson, additional: usize) !void {
        const next = std.math.add(
            usize,
            self.output.written().len,
            additional,
        ) catch return error.ObservationOutputBytesExceeded;
        if (next > self.max_bytes) {
            return error.ObservationOutputBytesExceeded;
        }
    }
};

fn canonicalStringLength(value: []const u8) !usize {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    var length: usize = 2;
    for (value) |byte| {
        const additional: usize = switch (byte) {
            '"', '\\', 0x08, 0x09, 0x0a, 0x0c, 0x0d => 2,
            0x00...0x07, 0x0b, 0x0e...0x1f => 6,
            else => 1,
        };
        length = std.math.add(usize, length, additional) catch
            return error.ObservationOutputBytesExceeded;
    }
    return length;
}

fn renderForAllocationFailure(
    allocator: std.mem.Allocator,
    envelope: Envelope,
) !void {
    const rendered = renderJsonAlloc(allocator, envelope) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(rendered);
}

test "observation result preserves identities provenance limits and no authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/result","requires":{"abi":"seq-observation-abi/v1","operators":["project"]},"parameters":{},"selectors":[],"relations":[],"inputs":[{"name":"facts","schema":"example-facts/v1","fields":[{"name":"id","type":"string","nullable":false},{"name":"score","type":"float","nullable":false},{"name":"detail","type":"json","nullable":true}],"max_rows":10,"max_bytes":4096}],"pipeline":[{"op":"project","input":"facts","as":"rows","fields":["id","score","detail"]}],"projections":{"rows":{"relation":"rows","schema":"example-rows/v1","fields":["id","score","detail"],"renderers":["json"]}},"bounds":{"max_rows":10,"max_output_bytes":8192,"max_fold_states":2,"max_input_bytes":4096}}
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
    var bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{},
    );
    defer bindings.deinit(std.testing.allocator);
    const values = [_]execution.Value{
        .{ .string = "row\none" },
        .{ .float = 1.5 },
        .{ .json = "{\"a\":1}" },
    };
    const rendered = try renderJsonAlloc(std.testing.allocator, .{
        .definition_plan = &definition_plan,
        .projection_name = "rows",
        .parameters_digest = &bindings.values_digest,
        .corpus = .{
            .adapter = "immutable-relation/v1",
            .digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            .files = 1,
            .sessions = 0,
            .contaminated = false,
        },
        .rows = .{ .values = &values, .width = 3 },
        .compile_stats = .{
            .cache_hit = true,
            .closure_files = 1,
            .closure_bytes = 1024,
        },
        .execution_stats = .{
            .rows_scanned = 1,
            .output_rows = 1,
        },
        .limitations = &.{"external facts are caller supplied"},
    });
    defer std.testing.allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        rendered,
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(
        schema,
        root.get("schema").?.string,
    );
    try std.testing.expect(!root.get("authority_granted").?.bool);
    try std.testing.expectEqualStrings(
        "row\none",
        root.get("data").?.object.get("rows").?.array.items[0]
            .object.get("id").?.string,
    );
    try std.testing.expectEqualStrings(
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        root.get("corpus").?.object.get("digest").?.string,
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        renderForAllocationFailure,
        .{Envelope{
            .definition_plan = &definition_plan,
            .projection_name = "rows",
            .parameters_digest = &bindings.values_digest,
            .corpus = .{
                .adapter = "immutable-relation/v1",
                .digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
                .files = 1,
                .sessions = 0,
                .contaminated = false,
            },
            .rows = .{ .values = &values, .width = 3 },
            .compile_stats = .{},
            .execution_stats = .{ .output_rows = 1 },
        }},
    );
}

test "observation result fails before emitting beyond the declared byte bound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/result-bound","requires":{"abi":"seq-observation-abi/v1","operators":["project"]},"parameters":{},"selectors":[],"relations":[],"inputs":[{"name":"facts","schema":"example-facts/v1","fields":[{"name":"id","type":"string","nullable":false}],"max_rows":1,"max_bytes":1024}],"pipeline":[{"op":"project","input":"facts","as":"rows","fields":["id"]}],"projections":{"rows":{"relation":"rows","schema":"example-rows/v1","fields":["id"],"renderers":["json"]}},"bounds":{"max_rows":1,"max_output_bytes":64,"max_fold_states":1,"max_input_bytes":1024}}
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
    const values = [_]execution.Value{.{ .string = "bounded" }};
    try std.testing.expectError(
        error.ObservationOutputBytesExceeded,
        renderJsonAlloc(std.testing.allocator, .{
            .definition_plan = &definition_plan,
            .projection_name = "rows",
            .parameters_digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            .corpus = .{
                .adapter = "immutable-relation/v1",
                .digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
                .files = 1,
                .sessions = 0,
                .contaminated = false,
            },
            .rows = .{ .values = &values, .width = 1 },
            .compile_stats = .{},
            .execution_stats = .{ .output_rows = 1 },
        }),
    );
}
