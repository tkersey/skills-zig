const std = @import("std");
const execution = @import("execution.zig");
const physical = @import("physical.zig");

pub const adapter_id = "opencode-prompt-history-jsonl/v1";
pub const session_id = "opencode-prompt-history";

pub const Metrics = struct {
    bytes_read: usize,
    records: usize,
    warnings: usize,
    digest: [71]u8,
};

pub fn recognizes(path: []const u8) bool {
    return std.mem.eql(
        u8,
        std.fs.path.basename(path),
        "prompt-history.jsonl",
    );
}

pub fn feedFile(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    runner: *execution.Runner,
    path: []const u8,
    max_input_bytes: usize,
) !Metrics {
    const relation = switch (program.source) {
        .physical => |value| value,
        .external => return error.ObservationRequiresExternalInput,
    };
    const raw = try readFileAlloc(allocator, path, max_input_bytes);
    defer allocator.free(raw);
    var records: usize = 0;
    var warnings: usize = 0;
    var tools: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |untrimmed| {
        const line = std.mem.trim(u8, untrimmed, " \t\r");
        if (line.len == 0) continue;
        records += 1;
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .parse_numbers = false },
        ) catch {
            warnings += 1;
            continue;
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => {
                warnings += 1;
                continue;
            },
        };
        tools += toolCount(object);
        if (relation == .sessions) continue;
        const feed = try feedRecord(
            allocator,
            program,
            runner,
            relation,
            path,
            line,
            records,
            object,
        );
        if (feed == .stop) break;
    }
    if (relation == .sessions and !runner.stopped) {
        var row_storage: [256]execution.Value = undefined;
        const row = row_storage[0..program.source_width];
        try fillSession(row, program.source_field_indices, path, records, tools);
        _ = try runner.feed(row);
    }
    return .{
        .bytes_read = raw.len,
        .records = records,
        .warnings = warnings,
        .digest = digest(raw),
    };
}

fn feedRecord(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    runner: *execution.Runner,
    relation: physical.Relation,
    path: []const u8,
    raw: []const u8,
    record_index: usize,
    object: std.json.ObjectMap,
) !execution.Feed {
    var row_storage: [256]execution.Value = undefined;
    const row = row_storage[0..program.source_width];
    switch (relation) {
        .source_events => {
            try fillSourceEvent(
                row,
                program.source_field_indices,
                path,
                raw,
                record_index,
                object,
            );
            return runner.feed(row);
        },
        .messages => {
            try fillMessage(
                row,
                program.source_field_indices,
                path,
                record_index,
                object,
            );
            return runner.feed(row);
        },
        .turns => {
            try fillTurn(
                row,
                program.source_field_indices,
                path,
                record_index,
                object,
            );
            return runner.feed(row);
        },
        .tool_invocations,
        .tool_results,
        .tool_lifecycle,
        => return feedTools(
            allocator,
            program,
            runner,
            relation,
            path,
            record_index,
            object,
        ),
        .structured_documents => {
            try fillStructuredDocument(
                row,
                program.source_field_indices,
                raw,
                record_index,
            );
            return runner.feed(row);
        },
        .sessions,
        .session_edges,
        .token_events,
        .structured_values,
        => return .continue_scanning,
    }
}

fn feedTools(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    runner: *execution.Runner,
    relation: physical.Relation,
    path: []const u8,
    record_index: usize,
    object: std.json.ObjectMap,
) !execution.Feed {
    const parts = arrayField(object, "parts") orelse
        return .continue_scanning;
    var row_storage: [256]execution.Value = undefined;
    const row = row_storage[0..program.source_width];
    for (parts.items, 0..) |part, part_index| {
        const part_object = switch (part) {
            .object => |value| value,
            else => continue,
        };
        if (!std.mem.eql(
            u8,
            stringField(part_object, "type") orelse "",
            "tool",
        )) continue;
        const state = objectField(part_object, "state");
        const input_json = if (state) |value|
            if (value.get("input")) |input|
                try std.json.Stringify.valueAlloc(allocator, input, .{})
            else
                null
        else
            null;
        defer if (input_json) |value| allocator.free(value);
        try fillTool(
            row,
            program.source_field_indices,
            relation,
            path,
            record_index,
            part_index,
            part_object,
            state,
            input_json,
        );
        if (try runner.feed(row) == .stop) return .stop;
    }
    return .continue_scanning;
}

fn fillSession(
    row: []execution.Value,
    fields: []const u16,
    path: []const u8,
    records: usize,
    _: usize,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => .{ .string = session_id },
            1 => .{ .string = path },
            8 => .{ .string = "opencode" },
            13 => try usizeInteger(records),
            19, 21, 22 => .{ .boolean = false },
            23 => .{ .integer = 0 },
            2...7, 9...12, 14...18, 20 => .null,
            else => return error.InvalidOpenCodePhysicalFieldIndex,
        };
    }
}

fn fillSourceEvent(
    row: []execution.Value,
    fields: []const u16,
    path: []const u8,
    raw: []const u8,
    record_index: usize,
    object: std.json.ObjectMap,
) !void {
    var id_buffer: [64]u8 = undefined;
    const id = try recordId(&id_buffer, record_index);
    const input = stringField(object, "input");
    const mode = stringField(object, "mode");
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => .{ .string = id },
            1 => .{ .string = session_id },
            2 => .{ .string = path },
            3 => try usizeInteger(record_index),
            4 => .{ .string = "prompt_history" },
            5 => optionalString(mode),
            6 => .null,
            7, 8 => .{ .json = raw },
            9 => .{ .string = "opencode_jsonl" },
            10 => try usizeInteger(record_index - 1),
            11 => .{ .string = "user" },
            12 => optionalString(input),
            13 => .{ .boolean = false },
            else => return error.InvalidOpenCodePhysicalFieldIndex,
        };
    }
}

fn fillMessage(
    row: []execution.Value,
    fields: []const u16,
    path: []const u8,
    record_index: usize,
    object: std.json.ObjectMap,
) !void {
    var id_buffer: [64]u8 = undefined;
    const id = try recordId(&id_buffer, record_index);
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0, 6 => .{ .string = id },
            1 => .{ .string = session_id },
            2 => try usizeInteger(record_index - 1),
            3 => .{ .string = "user" },
            4 => optionalString(stringField(object, "input")),
            5 => .null,
            7 => .{ .string = path },
            8 => .{ .boolean = false },
            else => return error.InvalidOpenCodePhysicalFieldIndex,
        };
    }
}

fn fillTurn(
    row: []execution.Value,
    fields: []const u16,
    path: []const u8,
    record_index: usize,
    object: std.json.ObjectMap,
) !void {
    var id_buffer: [64]u8 = undefined;
    const id = try recordId(&id_buffer, record_index);
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => .{ .string = session_id },
            1 => .{ .string = path },
            2 => .{ .string = id },
            3 => try usizeInteger(record_index - 1),
            7 => .{ .string = "observed" },
            9 => optionalString(stringField(object, "input")),
            19 => try usizeInteger(toolCount(object)),
            20 => .{ .boolean = false },
            24 => .{ .integer = 0 },
            4...6, 8, 10...18, 21...23 => .null,
            else => return error.InvalidOpenCodePhysicalFieldIndex,
        };
    }
}

fn fillTool(
    row: []execution.Value,
    fields: []const u16,
    relation: physical.Relation,
    path: []const u8,
    record_index: usize,
    part_index: usize,
    part: std.json.ObjectMap,
    state: ?std.json.ObjectMap,
    input_json: ?[]const u8,
) !void {
    var id_buffer: [96]u8 = undefined;
    const fallback_id = try std.fmt.bufPrint(
        &id_buffer,
        "opencode:{d}:tool:{d}",
        .{ record_index, part_index + 1 },
    );
    const call_id = stringField(part, "callID") orelse fallback_id;
    const tool = stringField(part, "tool");
    const status = if (state) |value| stringField(value, "status") else null;
    const output = if (state) |value| stringField(value, "output") else null;
    const command = if (state) |value|
        if (objectField(value, "input")) |input|
            stringField(input, "command")
        else
            null
    else
        null;
    const exit_code = if (state) |value|
        if (objectField(value, "metadata")) |metadata|
            integerField(metadata, "exit")
        else
            null
    else
        null;
    const start = if (state) |value|
        if (objectField(value, "time")) |time|
            integerField(time, "start")
        else
            null
    else
        null;
    const end = if (state) |value|
        if (objectField(value, "time")) |time|
            integerField(time, "end")
        else
            null
    else
        null;
    for (fields, 0..) |field, index| {
        row[index] = switch (relation) {
            .tool_invocations => switch (field) {
                0 => .{ .string = call_id },
                1 => .{ .string = session_id },
                2 => .null,
                3 => try usizeInteger(record_index - 1),
                4 => .null,
                5 => .{ .string = "tool" },
                6 => optionalString(tool),
                7 => .{ .string = "opencode" },
                8 => optionalJson(input_json),
                9 => optionalString(command),
                10 => optionalString(command),
                11 => .null,
                12 => .null,
                13 => .{ .string = path },
                else => return error.InvalidOpenCodePhysicalFieldIndex,
            },
            .tool_results => switch (field) {
                0 => .{ .string = call_id },
                1 => .{ .string = session_id },
                2 => .null,
                3 => try usizeInteger(record_index - 1),
                4 => .null,
                5 => optionalString(output),
                6 => optionalInteger(exit_code),
                7 => optionalDuration(start, end),
                8, 9 => .null,
                10 => .null,
                11 => .{ .string = path },
                else => return error.InvalidOpenCodePhysicalFieldIndex,
            },
            .tool_lifecycle => switch (field) {
                0 => .{ .string = call_id },
                1 => .{ .string = session_id },
                2 => .null,
                3 => try usizeInteger(record_index - 1),
                4, 5 => .null,
                6 => .{ .string = "tool" },
                7 => optionalString(tool),
                8 => .{ .string = "opencode" },
                9 => optionalJson(input_json),
                10 => optionalString(command),
                11 => optionalString(output),
                12 => optionalString(command),
                13 => .null,
                14 => optionalInteger(exit_code),
                15 => optionalDuration(start, end),
                16 => optionalString(status),
                17 => try usizeInteger(record_index),
                18 => try usizeInteger(record_index),
                19 => .{ .string = path },
                else => return error.InvalidOpenCodePhysicalFieldIndex,
            },
            else => unreachable,
        };
    }
}

fn fillStructuredDocument(
    row: []execution.Value,
    fields: []const u16,
    raw: []const u8,
    record_index: usize,
) !void {
    var id_buffer: [64]u8 = undefined;
    const id = try recordId(&id_buffer, record_index);
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0, 3 => .{ .string = id },
            1 => .{ .string = "opencode-prompt-history-entry" },
            2 => .{ .json = raw },
            4 => .{ .string = session_id },
            5 => try usizeInteger(record_index - 1),
            6 => .null,
            else => return error.InvalidOpenCodePhysicalFieldIndex,
        };
    }
}

fn toolCount(object: std.json.ObjectMap) usize {
    const parts = arrayField(object, "parts") orelse return 0;
    var count: usize = 0;
    for (parts.items) |part| {
        const item = switch (part) {
            .object => |value| value,
            else => continue,
        };
        if (std.mem.eql(
            u8,
            stringField(item, "type") orelse "",
            "tool",
        )) count += 1;
    }
    return count;
}

fn readFileAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > max_bytes) {
        return error.ObservationInputByteBoundExceeded;
    }
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

fn digest(raw: []const u8) [71]u8 {
    var bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw, &bytes, .{});
    const hex = std.fmt.bytesToHex(bytes, .lower);
    var encoded: [71]u8 = undefined;
    @memcpy(encoded[0..7], "sha256:");
    @memcpy(encoded[7..], &hex);
    return encoded;
}

fn recordId(buffer: []u8, index: usize) ![]const u8 {
    return std.fmt.bufPrint(buffer, "opencode:{d}", .{index});
}

fn objectField(
    object: std.json.ObjectMap,
    name: []const u8,
) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .object => |result| result,
        else => null,
    };
}

fn arrayField(
    object: std.json.ObjectMap,
    name: []const u8,
) ?std.json.Array {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .array => |result| result,
        else => null,
    };
}

fn stringField(
    object: std.json.ObjectMap,
    name: []const u8,
) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |result| result,
        else => null,
    };
}

fn integerField(
    object: std.json.ObjectMap,
    name: []const u8,
) ?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |result| result,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn optionalString(value: ?[]const u8) execution.Value {
    return if (value) |text| .{ .string = text } else .null;
}

fn optionalJson(value: ?[]const u8) execution.Value {
    return if (value) |text| .{ .json = text } else .null;
}

fn optionalInteger(value: ?i64) execution.Value {
    return if (value) |number| .{ .integer = number } else .null;
}

fn optionalDuration(start: ?i64, end: ?i64) execution.Value {
    if (start == null or end == null or end.? < start.?) return .null;
    return .{ .integer = end.? - start.? };
}

fn usizeInteger(value: usize) !execution.Value {
    return .{ .integer = std.math.cast(i64, value) orelse
        return error.ObservationIntegerOverflow };
}

test "adapter recognizes only the OpenCode prompt-history source" {
    try std.testing.expect(recognizes("/tmp/prompt-history.jsonl"));
    try std.testing.expect(!recognizes("/tmp/rollout.jsonl"));
}
