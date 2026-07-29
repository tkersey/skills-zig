const std = @import("std");
const execution = @import("execution.zig");
const jsonl_core = @import("jsonl_core");
const physical = @import("physical.zig");

pub const adapter_id = "opencode-prompt-history-jsonl/v1";

pub const Metrics = struct {
    bytes_read: usize,
    records: usize,
    warnings: usize,
    digest: [71]u8,
};

pub const Selection = struct {
    status: ?[]const u8 = null,
    contains: ?[]const u8 = null,
};

const ScanResult = struct {
    records: usize,
    source_records: usize,
    warnings: usize,
    tools: usize,
    session_matches: bool,
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
    return feedFileSelected(
        allocator,
        program,
        runner,
        path,
        max_input_bytes,
        .{},
    );
}

pub fn feedFileSelected(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    runner: *execution.Runner,
    path: []const u8,
    max_input_bytes: usize,
    selection: Selection,
) !Metrics {
    const relation = switch (program.source) {
        .physical => |value| value,
        .external => return error.ObservationRequiresExternalInput,
    };
    if (relation == .structured_values) {
        return error.OpenCodeStructuredValuesUnavailable;
    }
    var session_id_buffer: [64]u8 = undefined;
    const session_id = try sessionId(&session_id_buffer, path);
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try openFile(io, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > max_input_bytes) {
        return error.ObservationInputByteBoundExceeded;
    }
    var reader = file.reader(io, &.{});
    var digest_observer = DigestObserver{ .max_bytes = max_input_bytes };
    var stream = try jsonl_core.Stream.init(
        allocator,
        &reader.interface,
        .{
            .max_line_bytes = max_input_bytes,
            .chunk_observer = .{
                .context = &digest_observer,
                .observeFn = DigestObserver.observe,
            },
        },
    );
    defer stream.deinit();
    const scanned = try scanStream(
        allocator,
        program,
        runner,
        relation,
        session_id,
        path,
        &stream,
        selection,
    );
    if (relation == .sessions and !runner.stopped and
        scanned.session_matches)
    {
        var row_storage: [256]execution.Value = undefined;
        const row = row_storage[0..program.source_width];
        try fillSession(
            row,
            program.source_field_indices,
            session_id,
            path,
            scanned.records,
            scanned.tools,
        );
        _ = try runner.feed(row);
    }
    return .{
        .bytes_read = digest_observer.bytes_read,
        .records = scanned.records,
        .warnings = scanned.warnings,
        .digest = digest_observer.final(),
    };
}

const DigestObserver = struct {
    max_bytes: usize,
    bytes_read: usize = 0,
    hasher: std.crypto.hash.sha2.Sha256 =
        std.crypto.hash.sha2.Sha256.init(.{}),

    fn observe(context: *anyopaque, bytes: []const u8) !void {
        const self: *DigestObserver = @ptrCast(@alignCast(context));
        self.bytes_read = std.math.add(
            usize,
            self.bytes_read,
            bytes.len,
        ) catch return error.ObservationInputByteBoundExceeded;
        if (self.bytes_read > self.max_bytes) {
            return error.ObservationInputByteBoundExceeded;
        }
        self.hasher.update(bytes);
    }

    fn final(self: DigestObserver) [71]u8 {
        var mutable = self;
        var bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        mutable.hasher.final(&bytes);
        return encodeDigest(bytes);
    }
};

fn scanStream(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    runner: *execution.Runner,
    relation: physical.Relation,
    session_id: []const u8,
    path: []const u8,
    stream: *jsonl_core.Stream,
    selection: Selection,
) !ScanResult {
    var result = initialScanResult(path, selection);
    var emission_stopped = false;
    while (try stream.next()) |line| {
        result.source_records = line.number;
        const feed = try scanRecordLine(
            allocator,
            program,
            runner,
            relation,
            session_id,
            path,
            line.bytes,
            selection,
            &result,
            !emission_stopped,
        );
        if (feed == .stop) emission_stopped = true;
    }
    return result;
}

fn scanRecords(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    runner: *execution.Runner,
    relation: physical.Relation,
    session_id: []const u8,
    path: []const u8,
    raw: []const u8,
    selection: Selection,
) !ScanResult {
    var result = initialScanResult(path, selection);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var emission_stopped = false;
    while (lines.next()) |untrimmed| {
        result.source_records += 1;
        const feed = try scanRecordLine(
            allocator,
            program,
            runner,
            relation,
            session_id,
            path,
            untrimmed,
            selection,
            &result,
            !emission_stopped,
        );
        if (feed == .stop) emission_stopped = true;
    }
    return result;
}

fn initialScanResult(path: []const u8, selection: Selection) ScanResult {
    return .{
        .records = 0,
        .source_records = 0,
        .warnings = 0,
        .tools = 0,
        .session_matches = selection.contains == null or
            containsIgnoreCase(path, selection.contains.?),
    };
}

fn scanRecordLine(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    runner: *execution.Runner,
    relation: physical.Relation,
    session_id: []const u8,
    path: []const u8,
    untrimmed: []const u8,
    selection: Selection,
    result: *ScanResult,
    emit: bool,
) !execution.Feed {
    const line = std.mem.trim(u8, untrimmed, " \t\r");
    if (line.len == 0) return .continue_scanning;
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        line,
        .{ .parse_numbers = false },
    ) catch {
        result.warnings += 1;
        return .continue_scanning;
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => {
            result.warnings += 1;
            return .continue_scanning;
        },
    };
    if (stringField(object, "input") == null) {
        result.warnings += 1;
        return .continue_scanning;
    }
    result.records += 1;
    result.session_matches = result.session_matches or
        (selection.contains != null and
            containsIgnoreCase(stringField(object, "input"), selection.contains.?));
    result.tools += toolCount(object);
    if (!emit) return .continue_scanning;
    if (relation == .sessions or
        (relation == .turns and !turnPasses(object, path, selection)))
    {
        return .continue_scanning;
    }
    return feedRecord(
        allocator,
        program,
        runner,
        relation,
        session_id,
        path,
        line,
        result.records,
        result.source_records,
        object,
    );
}

fn turnPasses(
    object: std.json.ObjectMap,
    path: []const u8,
    selection: Selection,
) bool {
    if (selection.status) |status| {
        if (!std.mem.eql(u8, status, "observed")) return false;
    }
    if (selection.contains) |needle| {
        if (!containsIgnoreCase(stringField(object, "input"), needle) and
            !containsIgnoreCase(path, needle))
        {
            return false;
        }
    }
    return true;
}

fn feedRecord(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    runner: *execution.Runner,
    relation: physical.Relation,
    session_id: []const u8,
    path: []const u8,
    raw: []const u8,
    turn_number: usize,
    source_record_number: usize,
    object: std.json.ObjectMap,
) !execution.Feed {
    var row_storage: [256]execution.Value = undefined;
    const row = row_storage[0..program.source_width];
    var record_id_buffer: [96]u8 = undefined;
    const record_id = try recordId(
        &record_id_buffer,
        session_id,
        source_record_number,
    );
    if (relation == .tool_invocations or
        relation == .tool_results or
        relation == .tool_lifecycle)
    {
        return feedTools(
            allocator,
            program,
            runner,
            relation,
            session_id,
            path,
            turn_number,
            source_record_number,
            object,
        );
    }
    return feedNonToolRecord(
        runner,
        row,
        program.source_field_indices,
        relation,
        session_id,
        record_id,
        path,
        raw,
        turn_number,
        source_record_number,
        object,
    );
}

fn feedNonToolRecord(
    runner: *execution.Runner,
    row: []execution.Value,
    fields: []const u16,
    relation: physical.Relation,
    session_id: []const u8,
    record_id: []const u8,
    path: []const u8,
    raw: []const u8,
    turn_number: usize,
    source_record_number: usize,
    object: std.json.ObjectMap,
) !execution.Feed {
    switch (relation) {
        .source_events => return feedSourceEvent(
            runner,
            row,
            fields,
            session_id,
            record_id,
            path,
            raw,
            source_record_number,
            turn_number,
            object,
        ),
        .messages => return feedMessage(
            runner,
            row,
            fields,
            session_id,
            record_id,
            path,
            turn_number,
            object,
        ),
        .turns => return feedTurn(
            runner,
            row,
            fields,
            session_id,
            record_id,
            path,
            turn_number,
            object,
        ),
        .structured_documents => return feedStructuredDocument(
            runner,
            row,
            fields,
            session_id,
            record_id,
            raw,
            turn_number - 1,
        ),
        .sessions,
        .session_edges,
        .token_events,
        .structured_values,
        .tool_invocations,
        .tool_results,
        .tool_lifecycle,
        => return .continue_scanning,
    }
}

fn feedSourceEvent(
    runner: *execution.Runner,
    row: []execution.Value,
    fields: []const u16,
    session_id: []const u8,
    record_id: []const u8,
    path: []const u8,
    raw: []const u8,
    source_record_number: usize,
    turn_number: usize,
    object: std.json.ObjectMap,
) !execution.Feed {
    try fillSourceEvent(
        row,
        fields,
        session_id,
        record_id,
        path,
        raw,
        source_record_number,
        turn_number,
        object,
    );
    return runner.feed(row);
}

fn feedMessage(
    runner: *execution.Runner,
    row: []execution.Value,
    fields: []const u16,
    session_id: []const u8,
    record_id: []const u8,
    path: []const u8,
    turn_number: usize,
    object: std.json.ObjectMap,
) !execution.Feed {
    try fillMessage(
        row,
        fields,
        session_id,
        record_id,
        path,
        turn_number,
        object,
    );
    return runner.feed(row);
}

fn feedTurn(
    runner: *execution.Runner,
    row: []execution.Value,
    fields: []const u16,
    session_id: []const u8,
    record_id: []const u8,
    path: []const u8,
    turn_number: usize,
    object: std.json.ObjectMap,
) !execution.Feed {
    try fillTurn(
        row,
        fields,
        session_id,
        record_id,
        path,
        turn_number,
        object,
    );
    return runner.feed(row);
}

fn feedStructuredDocument(
    runner: *execution.Runner,
    row: []execution.Value,
    fields: []const u16,
    session_id: []const u8,
    record_id: []const u8,
    raw: []const u8,
    turn_index: usize,
) !execution.Feed {
    try fillStructuredDocument(
        row,
        fields,
        session_id,
        record_id,
        raw,
        turn_index,
    );
    return runner.feed(row);
}

fn feedTools(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    runner: *execution.Runner,
    relation: physical.Relation,
    session_id: []const u8,
    path: []const u8,
    turn_number: usize,
    source_record_number: usize,
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
        const status = optionalObjectString(state, "status") orelse "unknown";
        if (relation == .tool_results and !terminalToolStatus(status)) {
            continue;
        }
        const input_json = if (state) |value|
            if (value.get("input")) |input|
                try std.json.Stringify.valueAlloc(allocator, input, .{})
            else
                null
        else
            null;
        defer if (input_json) |value| allocator.free(value);
        var id_buffer: [96]u8 = undefined;
        const call_id = try toolId(
            &id_buffer,
            path,
            stringField(part_object, "callID"),
            source_record_number,
            part_index + 1,
        );
        try fillTool(
            row,
            program.source_field_indices,
            relation,
            session_id,
            path,
            turn_number,
            call_id,
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
    session_id: []const u8,
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
    session_id: []const u8,
    record_id: []const u8,
    path: []const u8,
    raw: []const u8,
    source_record_number: usize,
    turn_number: usize,
    object: std.json.ObjectMap,
) !void {
    const input = stringField(object, "input");
    const mode = stringField(object, "mode");
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => .{ .string = record_id },
            1 => .{ .string = session_id },
            2 => .{ .string = path },
            3 => try usizeInteger(source_record_number),
            4 => .{ .string = "prompt_history" },
            5 => optionalString(mode),
            6 => .null,
            7, 8 => .{ .json = raw },
            9 => .{ .string = "opencode_jsonl" },
            10 => try usizeInteger(turn_number - 1),
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
    session_id: []const u8,
    record_id: []const u8,
    path: []const u8,
    record_index: usize,
    object: std.json.ObjectMap,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0, 6 => .{ .string = record_id },
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
    session_id: []const u8,
    record_id: []const u8,
    path: []const u8,
    record_index: usize,
    object: std.json.ObjectMap,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => .{ .string = session_id },
            1 => .{ .string = path },
            2 => .{ .string = record_id },
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
    session_id: []const u8,
    path: []const u8,
    record_index: usize,
    call_id: []const u8,
    part: std.json.ObjectMap,
    state: ?std.json.ObjectMap,
    input_json: ?[]const u8,
) !void {
    const values = ToolValues{
        .call_id = call_id,
        .session_id = session_id,
        .tool = stringField(part, "tool"),
        .status = optionalObjectString(state, "status") orelse "unknown",
        .output = optionalObjectString(state, "output"),
        .command = nestedObjectString(state, "input", "command"),
        .exit_code = nestedObjectInteger(state, "metadata", "exit"),
        .start = nestedObjectInteger(state, "time", "start"),
        .end = nestedObjectInteger(state, "time", "end"),
        .input_json = input_json,
        .path = path,
        .record_index = record_index,
    };
    for (fields, 0..) |field, index| {
        row[index] = try toolValue(relation, field, values);
    }
}

const ToolValues = struct {
    call_id: []const u8,
    session_id: []const u8,
    tool: ?[]const u8,
    status: []const u8,
    output: ?[]const u8,
    command: ?[]const u8,
    exit_code: ?i64,
    start: ?i64,
    end: ?i64,
    input_json: ?[]const u8,
    path: []const u8,
    record_index: usize,
};

fn toolValue(
    relation: physical.Relation,
    field: u16,
    values: ToolValues,
) !execution.Value {
    return switch (relation) {
        .tool_invocations => toolInvocationValue(field, values),
        .tool_results => toolResultValue(field, values),
        .tool_lifecycle => toolLifecycleValue(field, values),
        else => unreachable,
    };
}

fn toolInvocationValue(field: u16, values: ToolValues) !execution.Value {
    return switch (field) {
        0 => .{ .string = values.call_id },
        1 => .{ .string = values.session_id },
        2, 4, 11, 12 => .null,
        3 => try usizeInteger(values.record_index - 1),
        5 => .{ .string = "tool" },
        6 => optionalString(values.tool),
        7 => .{ .string = "opencode" },
        8 => optionalJson(values.input_json),
        9, 10 => optionalString(values.command),
        13 => .{ .string = values.path },
        else => return error.InvalidOpenCodePhysicalFieldIndex,
    };
}

fn toolResultValue(field: u16, values: ToolValues) !execution.Value {
    return switch (field) {
        0 => .{ .string = values.call_id },
        1 => .{ .string = values.session_id },
        2, 4, 8...10 => .null,
        3 => try usizeInteger(values.record_index - 1),
        5 => optionalString(values.output),
        6 => optionalInteger(values.exit_code),
        7 => optionalDuration(values.start, values.end),
        11 => .{ .string = values.path },
        else => return error.InvalidOpenCodePhysicalFieldIndex,
    };
}

fn toolLifecycleValue(field: u16, values: ToolValues) !execution.Value {
    return switch (field) {
        0 => .{ .string = values.call_id },
        1 => .{ .string = values.session_id },
        2, 4, 5, 13 => .null,
        3 => try usizeInteger(values.record_index - 1),
        6 => .{ .string = "tool" },
        7 => optionalString(values.tool),
        8 => .{ .string = "opencode" },
        9 => optionalJson(values.input_json),
        10, 12 => optionalString(values.command),
        11 => optionalString(values.output),
        14 => optionalInteger(values.exit_code),
        15 => optionalDuration(values.start, values.end),
        16 => .{ .string = values.status },
        17, 18 => try usizeInteger(values.record_index),
        19 => .{ .string = values.path },
        else => return error.InvalidOpenCodePhysicalFieldIndex,
    };
}

fn fillStructuredDocument(
    row: []execution.Value,
    fields: []const u16,
    session_id: []const u8,
    record_id: []const u8,
    raw: []const u8,
    turn_index: usize,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0, 3 => .{ .string = record_id },
            1 => .{ .string = "opencode-prompt-history-entry" },
            2 => .{ .json = raw },
            4 => .{ .string = session_id },
            5 => try usizeInteger(turn_index),
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

fn openFile(io: std.Io, path: []const u8) !std.Io.File {
    return if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
}

fn encodeDigest(bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8) [71]u8 {
    const hex = std.fmt.bytesToHex(bytes, .lower);
    var encoded: [71]u8 = undefined;
    @memcpy(encoded[0..7], "sha256:");
    @memcpy(encoded[7..], &hex);
    return encoded;
}

pub fn sessionId(buffer: []u8, path: []const u8) ![]const u8 {
    var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 =
        undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &digest_bytes, .{});
    const hex = std.fmt.bytesToHex(digest_bytes, .lower);
    return std.fmt.bufPrint(
        buffer,
        "opencode-session:{s}",
        .{hex[0..32]},
    );
}

fn recordId(
    buffer: []u8,
    session_id: []const u8,
    index: usize,
) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{s}:record:{d}",
        .{ session_id, index },
    );
}

fn toolId(
    buffer: []u8,
    path: []const u8,
    source_call_id: ?[]const u8,
    record_index: usize,
    part_index: usize,
) ![]const u8 {
    var fallback_buffer: [64]u8 = undefined;
    const identity = source_call_id orelse try std.fmt.bufPrint(
        &fallback_buffer,
        "record:{d}:part:{d}",
        .{ record_index, part_index },
    );
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(path);
    hasher.update(&.{0});
    hasher.update(identity);
    var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 =
        undefined;
    hasher.final(&digest_bytes);
    const hex = std.fmt.bytesToHex(digest_bytes, .lower);
    return std.fmt.bufPrint(buffer, "opencode-tool:{s}", .{hex[0..32]});
}

fn terminalToolStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "completed") or
        std.mem.eql(u8, status, "error") or
        std.mem.eql(u8, status, "failed") or
        std.mem.eql(u8, status, "cancelled");
}

fn containsIgnoreCase(value: ?[]const u8, needle: []const u8) bool {
    const text = value orelse return false;
    if (needle.len == 0) return true;
    if (needle.len > text.len) return false;
    var index: usize = 0;
    while (index + needle.len <= text.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(
            text[index .. index + needle.len],
            needle,
        )) return true;
    }
    return false;
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

fn optionalObjectString(
    object: ?std.json.ObjectMap,
    name: []const u8,
) ?[]const u8 {
    return if (object) |value| stringField(value, name) else null;
}

fn nestedObjectString(
    object: ?std.json.ObjectMap,
    child: []const u8,
    name: []const u8,
) ?[]const u8 {
    const parent = object orelse return null;
    const nested = objectField(parent, child) orelse return null;
    return stringField(nested, name);
}

fn nestedObjectInteger(
    object: ?std.json.ObjectMap,
    child: []const u8,
    name: []const u8,
) ?i64 {
    const parent = object orelse return null;
    const nested = objectField(parent, child) orelse return null;
    return integerField(nested, name);
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

const MaxRequestAllocator = struct {
    child: std.mem.Allocator,
    max_request_bytes: usize = 0,

    fn allocator(self: *MaxRequestAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn observe(self: *MaxRequestAllocator, bytes: usize) void {
        self.max_request_bytes = @max(self.max_request_bytes, bytes);
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *MaxRequestAllocator = @ptrCast(@alignCast(context));
        self.observe(len);
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *MaxRequestAllocator = @ptrCast(@alignCast(context));
        self.observe(new_len);
        return self.child.rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *MaxRequestAllocator = @ptrCast(@alignCast(context));
        self.observe(new_len);
        return self.child.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *MaxRequestAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
    }
};

fn writeLargePromptHistory(dir: std.Io.Dir) !usize {
    const valid_line = "{\"input\":\"one\"}\n";
    const invalid_prefix = "{malformed";
    const invalid_padding = 4096 - invalid_prefix.len - 1;
    const line_count = 512;
    var file = try dir.createFile(
        std.testing.io,
        "prompt-history.jsonl",
        .{},
    );
    defer file.close(std.testing.io);
    var writer = file.writer(std.testing.io, &.{});
    try writer.interface.writeAll(valid_line);
    var index: usize = 1;
    while (index < line_count) : (index += 1) {
        try writer.interface.writeAll(invalid_prefix);
        try writer.interface.splatByteAll('x', invalid_padding);
        try writer.interface.writeByte('\n');
    }
    return valid_line.len + 4096 * (line_count - 1);
}

fn singleSourceEventProgram(
    source_fields: []u16,
    output_fields: []u16,
) execution.Program {
    return .{
        .source = .{ .physical = .source_events },
        .source_width = 1,
        .source_field_indices = source_fields,
        .materialized_field_indices = &.{},
        .source_row_bound = null,
        .operations = &.{},
        .predicates = &.{},
        .sort_keys = &.{},
        .distinct_fields = &.{},
        .aggregate_metrics = &.{},
        .output_field_indices = output_fields,
        .limit_state_count = 0,
        .first_blocking_operation = null,
        .max_rows = 1,
    };
}

test "adapter recognizes only the OpenCode prompt-history source" {
    try std.testing.expect(recognizes("/tmp/prompt-history.jsonl"));
    try std.testing.expect(!recognizes("/tmp/rollout.jsonl"));
}

test "OpenCode prompt history streams aggregate input" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const line_count = 512;
    const expected_bytes = try writeLargePromptHistory(temporary.dir);
    const path = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "prompt-history.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(path);
    var source_fields = [_]u16{3};
    var output_fields = [_]u16{0};
    const program = singleSourceEventProgram(
        &source_fields,
        &output_fields,
    );
    var output: [1]execution.Value = undefined;
    var runner = try execution.Runner.init(&program, &output);
    defer runner.deinit();
    var tracking = MaxRequestAllocator{
        .child = std.testing.allocator,
    };
    const metrics = try feedFileSelected(
        tracking.allocator(),
        &program,
        &runner,
        path,
        4 * 1024 * 1024,
        .{},
    );
    const result = try runner.finish();
    try std.testing.expectEqual(expected_bytes, metrics.bytes_read);
    try std.testing.expectEqual(@as(usize, 1), metrics.records);
    try std.testing.expectEqual(line_count - 1, metrics.warnings);
    try std.testing.expectEqual(@as(usize, 1), result.row_count);
    try std.testing.expect(tracking.max_request_bytes < 128 * 1024);
}

test "OpenCode identities bind the immutable source path" {
    var first_session_buffer: [64]u8 = undefined;
    var second_session_buffer: [64]u8 = undefined;
    const first_session = try sessionId(
        &first_session_buffer,
        "/first/prompt-history.jsonl",
    );
    const second_session = try sessionId(
        &second_session_buffer,
        "/second/prompt-history.jsonl",
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        first_session,
        second_session,
    ));

    var first_tool_buffer: [64]u8 = undefined;
    var second_tool_buffer: [64]u8 = undefined;
    const first_tool = try toolId(
        &first_tool_buffer,
        "/first/prompt-history.jsonl",
        "call-1",
        1,
        0,
    );
    const second_tool = try toolId(
        &second_tool_buffer,
        "/second/prompt-history.jsonl",
        "call-1",
        1,
        0,
    );
    try std.testing.expect(!std.mem.eql(u8, first_tool, second_tool));
}

test "OpenCode tool results require a terminal lifecycle status" {
    try std.testing.expect(terminalToolStatus("completed"));
    try std.testing.expect(terminalToolStatus("failed"));
    try std.testing.expect(!terminalToolStatus("running"));
    try std.testing.expect(!terminalToolStatus("pending"));
}

test "OpenCode physical line numbers include blank source records" {
    var source_fields = [_]u16{3};
    var output_fields = [_]u16{0};
    const program = execution.Program{
        .source = .{ .physical = .source_events },
        .source_width = 1,
        .source_field_indices = &source_fields,
        .materialized_field_indices = &.{},
        .source_row_bound = null,
        .operations = &.{},
        .predicates = &.{},
        .sort_keys = &.{},
        .distinct_fields = &.{},
        .aggregate_metrics = &.{},
        .output_field_indices = &output_fields,
        .limit_state_count = 0,
        .first_blocking_operation = null,
        .max_rows = 2,
    };
    var output: [2]execution.Value = undefined;
    var runner = try execution.Runner.init(&program, &output);
    defer runner.deinit();
    const scanned = try scanRecords(
        std.testing.allocator,
        &program,
        &runner,
        .source_events,
        "session",
        "/tmp/prompt-history.jsonl",
        "\n{\"input\":\"one\"}\n\n{\"input\":\"two\"}",
        .{},
    );
    const result = try runner.finish();
    try std.testing.expectEqual(@as(usize, 4), scanned.source_records);
    try std.testing.expectEqual(@as(i64, 2), result.rows().row(0)[0].integer);
    try std.testing.expectEqual(@as(i64, 4), result.rows().row(1)[0].integer);
}

test "OpenCode validates trailing records after the row limit" {
    var source_fields = [_]u16{3};
    var output_fields = [_]u16{0};
    const program = execution.Program{
        .source = .{ .physical = .source_events },
        .source_width = 1,
        .source_field_indices = &source_fields,
        .materialized_field_indices = &.{},
        .source_row_bound = null,
        .operations = &.{},
        .predicates = &.{},
        .sort_keys = &.{},
        .distinct_fields = &.{},
        .aggregate_metrics = &.{},
        .output_field_indices = &output_fields,
        .limit_state_count = 0,
        .first_blocking_operation = null,
        .max_rows = 1,
    };
    var output: [1]execution.Value = undefined;
    var runner = try execution.Runner.init(&program, &output);
    defer runner.deinit();
    const scanned = try scanRecords(
        std.testing.allocator,
        &program,
        &runner,
        .source_events,
        "session",
        "/tmp/prompt-history.jsonl",
        "{\"input\":\"one\"}\n{malformed}\n",
        .{},
    );
    const result = try runner.finish();
    try std.testing.expectEqual(@as(usize, 3), scanned.source_records);
    try std.testing.expectEqual(@as(usize, 1), scanned.records);
    try std.testing.expectEqual(@as(usize, 1), scanned.warnings);
    try std.testing.expectEqual(@as(usize, 1), result.row_count);
}

test "OpenCode scan rejects renamed non-prompt records" {
    var source_fields = [_]u16{3};
    var output_fields = [_]u16{0};
    const program = execution.Program{
        .source = .{ .physical = .source_events },
        .source_width = 1,
        .source_field_indices = &source_fields,
        .materialized_field_indices = &.{},
        .source_row_bound = null,
        .operations = &.{},
        .predicates = &.{},
        .sort_keys = &.{},
        .distinct_fields = &.{},
        .aggregate_metrics = &.{},
        .output_field_indices = &output_fields,
        .limit_state_count = 0,
        .first_blocking_operation = null,
        .max_rows = 1,
    };
    var output: [1]execution.Value = undefined;
    var runner = try execution.Runner.init(&program, &output);
    defer runner.deinit();
    const scanned = try scanRecords(
        std.testing.allocator,
        &program,
        &runner,
        .source_events,
        "session",
        "/tmp/prompt-history.jsonl",
        "{\"type\":\"session_meta\",\"payload\":{}}\n",
        .{},
    );
    const result = try runner.finish();
    try std.testing.expectEqual(@as(usize, 0), scanned.records);
    try std.testing.expectEqual(@as(usize, 1), scanned.warnings);
    try std.testing.expectEqual(@as(usize, 0), result.row_count);
}
