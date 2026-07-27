const std = @import("std");
const definition_core = @import("definition_core");
const trace_core = @import("trace_core");
const execution = @import("execution.zig");

pub const Limits = struct {
    max_documents: usize = 4_096,
    max_document_bytes: usize = 4 * 1024 * 1024,
    max_values: usize = 100_000,
    max_depth: usize = 64,
    max_pointer_bytes: usize = 4_096,
    max_owned_bytes: usize = 16 * 1024 * 1024,
};

pub const Document = struct {
    document_id: [71]u8,
    document_type: ?[]const u8,
    canonical_json: []const u8,
    source_event_id: []const u8,
    session_id: ?[]const u8,
    turn_index: ?i64,
    timestamp: ?[]const u8,

    pub fn id(self: *const Document) []const u8 {
        return &self.document_id;
    }
};

pub const ValueRecord = struct {
    document_index: u32,
    json_pointer: []const u8,
    value_kind: []const u8,
    scalar_value: ?[]const u8,
};

pub const Index = struct {
    documents: std.ArrayList(Document) = .empty,
    values: std.ArrayList(ValueRecord) = .empty,
    owned_strings: std.ArrayList([]u8) = .empty,
    owned_bytes: usize = 0,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        for (self.owned_strings.items) |text| allocator.free(text);
        self.owned_strings.deinit(allocator);
        self.values.deinit(allocator);
        self.documents.deinit(allocator);
        self.* = .{};
    }

    fn own(
        self: *Index,
        allocator: std.mem.Allocator,
        text: []const u8,
        limits: Limits,
    ) ![]const u8 {
        const copy = try allocator.dupe(u8, text);
        return self.retain(allocator, copy, limits);
    }

    fn retain(
        self: *Index,
        allocator: std.mem.Allocator,
        text: []u8,
        limits: Limits,
    ) ![]const u8 {
        errdefer allocator.free(text);
        const next = std.math.add(
            usize,
            self.owned_bytes,
            text.len,
        ) catch return error.StructuredOwnedBytesExceeded;
        if (next > limits.max_owned_bytes) {
            return error.StructuredOwnedBytesExceeded;
        }
        try self.owned_strings.append(allocator, text);
        self.owned_bytes = next;
        return text;
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    trace: *const trace_core.CanonicalSessionTrace,
    include_values: bool,
    limits: Limits,
) !Index {
    var index = Index{};
    errdefer index.deinit(allocator);

    for (trace.tools.items) |tool| {
        const raw = std.mem.trim(u8, tool.output_text orelse continue, " \t\r\n");
        if (raw.len == 0 or !looksLikeJson(raw)) continue;
        if (raw.len > limits.max_document_bytes) {
            return error.StructuredDocumentBytesExceeded;
        }
        const finalized_line = tool.finalized_line orelse continue;
        const occurrence = occurrenceAtLine(trace, finalized_line) orelse
            return error.StructuredSourceEventMissing;
        if (index.documents.items.len == limits.max_documents) {
            return error.StructuredDocumentCountExceeded;
        }

        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            raw,
            .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
            },
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer parsed.deinit();

        const canonical = try canonicalJsonAlloc(
            allocator,
            parsed.value,
        );
        if (canonical.len > limits.max_document_bytes) {
            allocator.free(canonical);
            return error.StructuredDocumentBytesExceeded;
        }
        const retained_json = try index.retain(allocator, canonical, limits);
        const document_type = try recognizeType(
            &index,
            allocator,
            parsed.value,
            limits,
        );
        const document_index = index.documents.items.len;
        try index.documents.append(allocator, .{
            .document_id = documentId(retained_json),
            .document_type = document_type,
            .canonical_json = retained_json,
            .source_event_id = occurrence.sourceEventId(),
            .session_id = trace.session.session_id,
            .turn_index = tool.turn_index,
            .timestamp = occurrence.timestamp,
        });
        if (include_values) {
            const root_pointer = try index.own(allocator, "", limits);
            try appendValueTree(
                &index,
                allocator,
                parsed.value,
                root_pointer,
                @intCast(document_index),
                0,
                limits,
            );
        }
    }
    return index;
}

pub fn observe(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    index: *const Index,
    output: []execution.Value,
) !execution.Result {
    var runner = try execution.Runner.initAlloc(
        allocator,
        program,
        output,
    );
    defer runner.deinit();
    _ = try feed(&runner, program, index);
    return runner.finish();
}

pub fn feed(
    runner: *execution.Runner,
    program: *const execution.Program,
    index: *const Index,
) !execution.Feed {
    const relation = switch (program.source) {
        .physical => |value| value,
        .external => return error.ObservationRequiresExternalInput,
    };
    var row: [256]execution.Value = undefined;
    switch (relation) {
        .structured_documents => for (index.documents.items) |*document| {
            try fillDocument(
                row[0..program.source_width],
                program.source_field_indices,
                document,
            );
            if (try runner.feed(row[0..program.source_width]) == .stop) break;
        },
        .structured_values => for (index.values.items) |value| {
            if (value.document_index >= index.documents.items.len) {
                return error.StructuredDocumentIndexInvalid;
            }
            try fillValue(
                row[0..program.source_width],
                program.source_field_indices,
                &index.documents.items[value.document_index],
                value,
            );
            if (try runner.feed(row[0..program.source_width]) == .stop) break;
        },
        else => return error.ObservationRequiresStructuredRelation,
    }
    return if (runner.stopped) .stop else .continue_scanning;
}

fn fillDocument(
    row: []execution.Value,
    fields: []const u16,
    document: *const Document,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => .{ .string = document.id() },
            1 => optionalString(document.document_type),
            2 => .{ .json = document.canonical_json },
            3 => .{ .string = document.source_event_id },
            4 => optionalString(document.session_id),
            5 => optionalInteger(document.turn_index),
            6 => optionalString(document.timestamp),
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillValue(
    row: []execution.Value,
    fields: []const u16,
    document: *const Document,
    value: ValueRecord,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => .{ .string = document.id() },
            1 => .{ .string = value.json_pointer },
            2 => .{ .string = value.value_kind },
            3 => optionalString(value.scalar_value),
            4 => .{ .string = document.source_event_id },
            5 => optionalString(document.session_id),
            6 => optionalInteger(document.turn_index),
            7 => optionalString(document.timestamp),
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn appendValueTree(
    index: *Index,
    allocator: std.mem.Allocator,
    value: std.json.Value,
    pointer: []const u8,
    document_index: u32,
    depth: usize,
    limits: Limits,
) !void {
    if (depth > limits.max_depth) return error.StructuredDepthExceeded;
    if (index.values.items.len == limits.max_values) {
        return error.StructuredValueCountExceeded;
    }
    const scalar = try scalarText(index, allocator, value, limits);
    try index.values.append(allocator, .{
        .document_index = document_index,
        .json_pointer = pointer,
        .value_kind = valueKind(value),
        .scalar_value = scalar,
    });

    switch (value) {
        .object => |object| {
            const keys = try allocator.alloc([]const u8, object.count());
            defer allocator.free(keys);
            var iterator = object.iterator();
            var key_index: usize = 0;
            while (iterator.next()) |entry| : (key_index += 1) {
                keys[key_index] = entry.key_ptr.*;
            }
            std.mem.sort([]const u8, keys, {}, struct {
                fn lessThan(
                    _: void,
                    left: []const u8,
                    right: []const u8,
                ) bool {
                    return std.mem.lessThan(u8, left, right);
                }
            }.lessThan);
            for (keys) |key| {
                const child_pointer = try appendPointer(
                    index,
                    allocator,
                    pointer,
                    key,
                    limits,
                );
                try appendValueTree(
                    index,
                    allocator,
                    object.get(key).?,
                    child_pointer,
                    document_index,
                    depth + 1,
                    limits,
                );
            }
        },
        .array => |array| for (array.items, 0..) |child, child_index| {
            const child_pointer = try appendArrayPointer(
                index,
                allocator,
                pointer,
                child_index,
                limits,
            );
            try appendValueTree(
                index,
                allocator,
                child,
                child_pointer,
                document_index,
                depth + 1,
                limits,
            );
        },
        else => {},
    }
}

fn scalarText(
    index: *Index,
    allocator: std.mem.Allocator,
    value: std.json.Value,
    limits: Limits,
) !?[]const u8 {
    return switch (value) {
        .null, .array, .object => null,
        .bool => |flag| if (flag) "true" else "false",
        .integer => |number| try ownPrint(
            index,
            allocator,
            limits,
            "{d}",
            .{number},
        ),
        .float => blk: {
            const canonical = try canonicalJsonAlloc(
                allocator,
                value,
            );
            break :blk try index.retain(allocator, canonical, limits);
        },
        .number_string => |number| try index.own(
            allocator,
            number,
            limits,
        ),
        .string => |text| try index.own(allocator, text, limits),
    };
}

fn valueKind(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "boolean",
        .integer => "integer",
        .float => "float",
        .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn recognizeType(
    index: *Index,
    allocator: std.mem.Allocator,
    value: std.json.Value,
    limits: Limits,
) !?[]const u8 {
    if (value == .object) {
        if (value.object.get("schema")) |schema| {
            if (schema == .string) {
                return try index.own(allocator, schema.string, limits);
            }
        }
        if (value.object.get("type")) |kind| {
            if (kind == .string) {
                return try index.own(allocator, kind.string, limits);
            }
        }
    }
    return valueKind(value);
}

fn appendPointer(
    index: *Index,
    allocator: std.mem.Allocator,
    parent: []const u8,
    key: []const u8,
    limits: Limits,
) ![]const u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    writer.writer.writeAll(parent) catch return error.OutOfMemory;
    writer.writer.writeByte('/') catch return error.OutOfMemory;
    for (key) |byte| switch (byte) {
        '~' => writer.writer.writeAll("~0") catch return error.OutOfMemory,
        '/' => writer.writer.writeAll("~1") catch return error.OutOfMemory,
        else => writer.writer.writeByte(byte) catch return error.OutOfMemory,
    };
    const pointer = try writer.toOwnedSlice();
    if (pointer.len > limits.max_pointer_bytes) {
        allocator.free(pointer);
        return error.StructuredPointerBytesExceeded;
    }
    return index.retain(allocator, pointer, limits);
}

fn appendArrayPointer(
    index: *Index,
    allocator: std.mem.Allocator,
    parent: []const u8,
    child_index: usize,
    limits: Limits,
) ![]const u8 {
    const pointer = try std.fmt.allocPrint(
        allocator,
        "{s}/{d}",
        .{ parent, child_index },
    );
    if (pointer.len > limits.max_pointer_bytes) {
        allocator.free(pointer);
        return error.StructuredPointerBytesExceeded;
    }
    return index.retain(allocator, pointer, limits);
}

fn ownPrint(
    index: *Index,
    allocator: std.mem.Allocator,
    limits: Limits,
    comptime format: []const u8,
    args: anytype,
) ![]const u8 {
    const text = try std.fmt.allocPrint(allocator, format, args);
    return index.retain(allocator, text, limits);
}

fn occurrenceAtLine(
    trace: *const trace_core.CanonicalSessionTrace,
    line_number: i64,
) ?*const trace_core.TraceOccurrence {
    const wanted = std.math.cast(usize, line_number) orelse return null;
    var low: usize = 0;
    var high = trace.occurrences.items.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const candidate = &trace.occurrences.items[middle];
        if (candidate.line_number < wanted) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low == trace.occurrences.items.len or
        trace.occurrences.items[low].line_number != wanted)
    {
        return null;
    }
    return &trace.occurrences.items[low];
}

fn looksLikeJson(text: []const u8) bool {
    return switch (text[0]) {
        '{', '[', '"', '-', '0'...'9', 't', 'f', 'n' => true,
        else => false,
    };
}

fn documentId(canonical_json: []const u8) [71]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_json, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var identity: [71]u8 = undefined;
    @memcpy(identity[0..7], "sha256:");
    @memcpy(identity[7..], &hex);
    return identity;
}

fn canonicalJsonAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]u8 {
    return definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        value,
    ) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

fn optionalString(value: ?[]const u8) execution.Value {
    return if (value) |text| .{ .string = text } else .null;
}

fn optionalInteger(value: ?i64) execution.Value {
    return if (value) |number| .{ .integer = number } else .null;
}

fn buildForAllocationFailure(
    allocator: std.mem.Allocator,
    trace: *const trace_core.CanonicalSessionTrace,
) !void {
    var index = try build(allocator, trace, true, .{});
    defer index.deinit(allocator);
}

test "structured index canonicalizes and flattens tool result JSON" {
    const definition = @import("definition.zig");
    const plan = @import("plan.zig");

    const source =
        "{\"timestamp\":\"2026-07-26T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"structured-session\"}}\n" ++
        "{\"timestamp\":\"2026-07-26T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-1\"}}\n" ++
        "{\"timestamp\":\"2026-07-26T00:00:02Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"arguments\":\"{\\\"cmd\\\":\\\"demo\\\"}\",\"call_id\":\"call-1\"}}\n" ++
        "{\"timestamp\":\"2026-07-26T00:00:03Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"call-1\",\"output\":\"{\\\"nested\\\":{\\\"a/b\\\":true},\\\"schema\\\":\\\"demo/v1\\\",\\\"items\\\":[3]}\"}}\n";
    var trace = try trace_core.parseSessionTraceBytes(
        std.testing.allocator,
        "/structured.jsonl",
        source,
        0,
        .{
            .ongoing_threshold_secs = 0,
            .include_occurrences = true,
            .include_message_bodies = false,
        },
    );
    defer trace.deinit(std.testing.allocator);
    var index = try build(std.testing.allocator, &trace, true, .{});
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), index.documents.items.len);
    try std.testing.expectEqualStrings(
        "demo/v1",
        index.documents.items[0].document_type.?,
    );
    try std.testing.expectEqualStrings(
        "{\"items\":[3],\"nested\":{\"a/b\":true},\"schema\":\"demo/v1\"}",
        index.documents.items[0].canonical_json,
    );
    try std.testing.expectEqualStrings(
        "sha256:",
        index.documents.items[0].id()[0..7],
    );
    var saw_escaped_pointer = false;
    var saw_array_scalar = false;
    for (index.values.items) |value| {
        if (std.mem.eql(u8, value.json_pointer, "/nested/a~1b")) {
            saw_escaped_pointer = true;
            try std.testing.expectEqualStrings("boolean", value.value_kind);
            try std.testing.expectEqualStrings("true", value.scalar_value.?);
        }
        if (std.mem.eql(u8, value.json_pointer, "/items/0")) {
            saw_array_scalar = true;
            try std.testing.expectEqualStrings("integer", value.value_kind);
            try std.testing.expectEqualStrings("3", value.scalar_value.?);
        }
    }
    try std.testing.expect(saw_escaped_pointer);
    try std.testing.expect(saw_array_scalar);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/structured","requires":{"abi":"seq-observation-abi/v1","operators":["scan","filter","project"]},"parameters":{},"selectors":["path"],"relations":[{"name":"structured_values","fields":["document_id","json_pointer","value_kind","scalar_value","source_event_id"]}],"inputs":[],"pipeline":[{"op":"scan","relation":"structured_values","as":"source"},{"op":"filter","input":"source","as":"matched","where":[{"field":"json_pointer","op":"exact","value":"/nested/a~1b"}]},{"op":"project","input":"matched","as":"rows","fields":["document_id","value_kind","scalar_value","source_event_id"]}],"projections":{"rows":{"relation":"rows","schema":"example-structured-rows/v1","fields":["document_id","value_kind","scalar_value","source_event_id"],"renderers":["json"]}},"bounds":{"max_rows":10,"max_output_bytes":4096,"max_fold_states":2}}
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
    var native_plan = try plan.compile(
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
    var output: [4]execution.Value = undefined;
    const result = try observe(
        std.testing.allocator,
        &program,
        &index,
        &output,
    );
    try std.testing.expectEqual(@as(usize, 1), result.row_count);
    try std.testing.expectEqualStrings(
        index.documents.items[0].id(),
        result.rows().row(0)[0].string,
    );
    try std.testing.expectEqualStrings(
        "boolean",
        result.rows().row(0)[1].string,
    );
    try std.testing.expectEqualStrings("true", result.rows().row(0)[2].string);
    try std.testing.expectEqualStrings(
        index.documents.items[0].source_event_id,
        result.rows().row(0)[3].string,
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        buildForAllocationFailure,
        .{&trace},
    );
}
