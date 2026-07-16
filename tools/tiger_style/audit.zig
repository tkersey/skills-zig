const std = @import("std");
const lex = @import("lex.zig");
const limits = @import("limits.zig");

pub const Audit = struct {
    diagnostics: u32 = 0,
    files: u32 = 0,
    lines: u64 = 0,

    pub fn record(
        audit: *Audit,
        writer: anytype,
        path: []const u8,
        line_number: u32,
        rule: []const u8,
        message: []const u8,
    ) !void {
        if (audit.diagnostics == limits.diagnostics_max) {
            return error.DiagnosticLimitExceeded;
        }
        audit.diagnostics += 1;
        try writer.print(
            "{s}:{d}: tiger-style/{s}: {s}\n",
            .{ path, line_number, rule, message },
        );
    }
};

const FunctionState = struct {
    active: bool = false,
    body_started: bool = false,
    brace_depth: i32 = 0,
    name: ?[]const u8 = null,
    recursion_reported: bool = false,
    start_line: u32 = 0,
};

pub fn countFile(audit: *Audit) !void {
    if (audit.files == limits.files_max) return error.FileLimitExceeded;
    audit.files += 1;
}

pub fn file(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: anytype,
    path: []const u8,
    audit: *Audit,
    count_file: bool,
) !void {
    if (count_file) try countFile(audit);
    const input = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(limits.file_bytes_max),
    );
    defer allocator.free(input);

    try source(writer, path, input, audit);
}

pub fn source(
    writer: anytype,
    path: []const u8,
    input: []const u8,
    audit: *Audit,
) !void {
    var function = FunctionState{};
    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, input, '\n');

    while (lines.next()) |source_line| {
        if (line_number == limits.lines_per_file_max) return error.LineLimitExceeded;
        line_number += 1;
        audit.lines += 1;
        try line(writer, path, line_number, source_line, audit);
        try functionLine(writer, path, line_number, source_line, &function, audit);
    }

    if (function.active) {
        try audit.record(
            writer,
            path,
            function.start_line,
            "function-closure",
            "function or test block does not close within the file",
        );
    }
}

pub fn addedLine(
    writer: anytype,
    path: []const u8,
    line_number: u32,
    source_line: []const u8,
    audit: *Audit,
) !void {
    audit.lines += 1;
    try line(writer, path, line_number, source_line, audit);
}

fn line(
    writer: anytype,
    path: []const u8,
    line_number: u32,
    source_line: []const u8,
    audit: *Audit,
) !void {
    try lineLayout(writer, path, line_number, source_line, audit);
    try lineSemantics(writer, path, line_number, source_line, audit);
}

fn lineLayout(
    writer: anytype,
    path: []const u8,
    line_number: u32,
    source_line: []const u8,
    audit: *Audit,
) !void {
    if (source_line.len > limits.line_columns_max) {
        try audit.record(writer, path, line_number, "line-length", "line exceeds 100 columns");
    }
    if (std.mem.indexOfScalar(u8, source_line, '\t') != null) {
        try audit.record(writer, path, line_number, "tab", "use spaces instead of tab characters");
    }
    if (source_line.len == 0) return;
    const byte_last = source_line[source_line.len - 1];
    if (byte_last == ' ' or byte_last == '\t') {
        try audit.record(writer, path, line_number, "trailing-space", "remove trailing whitespace");
    }
}

fn lineSemantics(
    writer: anytype,
    path: []const u8,
    line_number: u32,
    source_line: []const u8,
    audit: *Audit,
) !void {
    if (lex.commentHasDebtMarker(source_line)) {
        try audit.record(
            writer,
            path,
            line_number,
            "technical-debt",
            "resolve TODO/FIXME/HACK before merge",
        );
    }
    if (lex.codeContains(source_line, "catch {}") or
        lex.codeContains(source_line, "catch unreachable"))
    {
        try audit.record(
            writer,
            path,
            line_number,
            "error-handling",
            "handle the error explicitly",
        );
    }
    if (lex.codeContains(source_line, "while (true)") and
        !lex.commentContains(source_line, "tiger: event-loop"))
    {
        try audit.record(
            writer,
            path,
            line_number,
            "loop-bound",
            "bound the loop or justify it with `tiger: event-loop`",
        );
    }
}

fn functionLine(
    writer: anytype,
    path: []const u8,
    line_number: u32,
    source_line: []const u8,
    function: *FunctionState,
    audit: *Audit,
) !void {
    if (!function.active) function.* = functionStart(source_line, line_number) orelse return;

    const delta = lex.braceDelta(source_line);
    function.brace_depth += @as(i32, @intCast(delta.open));
    function.brace_depth -= @as(i32, @intCast(delta.close));
    if (delta.open > 0) function.body_started = true;
    if (!function.body_started and lex.codeContains(source_line, ";")) {
        function.* = .{};
        return;
    }

    try recursion(writer, path, line_number, source_line, function, audit);
    if (function.body_started and function.brace_depth == 0) {
        try functionClose(writer, path, line_number, function, audit);
    } else if (function.brace_depth < 0) {
        try audit.record(
            writer,
            path,
            line_number,
            "brace-balance",
            "function brace depth became negative",
        );
        function.* = .{};
    }
}

fn functionStart(source_line: []const u8, line_number: u32) ?FunctionState {
    if (lex.functionName(source_line)) |name| {
        return .{ .active = true, .name = name, .start_line = line_number };
    }
    if (lex.isTestStart(source_line)) {
        return .{ .active = true, .name = null, .start_line = line_number };
    }
    return null;
}

fn functionClose(
    writer: anytype,
    path: []const u8,
    line_number: u32,
    function: *FunctionState,
    audit: *Audit,
) !void {
    const line_count = line_number - function.start_line + 1;
    if (line_count > limits.function_lines_max) {
        try audit.record(
            writer,
            path,
            function.start_line,
            "function-length",
            "function or test block exceeds 70 lines",
        );
    }
    function.* = .{};
}

fn recursion(
    writer: anytype,
    path: []const u8,
    line_number: u32,
    source_line: []const u8,
    function: *FunctionState,
    audit: *Audit,
) !void {
    if (!function.body_started or function.recursion_reported) return;
    const name = function.name orelse return;
    const body_line = if (line_number == function.start_line)
        lex.codeAfter(source_line, "{") orelse return
    else
        source_line;
    if (!lex.codeCallsFunction(body_line, name)) return;

    try audit.record(
        writer,
        path,
        line_number,
        "recursion",
        "replace direct recursion with an explicitly bounded iteration",
    );
    function.recursion_reported = true;
}

test "line audit covers expected and unexpected space" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result = Audit{};

    try source(&output.writer, "valid.zig",
        \\fn bounded() void {
        \\    var index: u32 = 0;
        \\    while (index < 2) : (index += 1) {}
        \\}
    , &result);
    try std.testing.expectEqual(@as(u32, 0), result.diagnostics);

    try source(&output.writer, "invalid.zig",
        \\fn unbounded() void {
        \\    while (true) {}
        \\    action() catch {};
        \\    // TODO: Remove the provisional path.
        \\}
    , &result);
    try std.testing.expectEqual(@as(u32, 3), result.diagnostics);
}

test "strings and justified event loops do not trigger code rules" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result = Audit{};

    try source(&output.writer, "strings.zig",
        \\fn server() void {
        \\    const example = "while (true) catch {}";
        \\    _ = example;
        \\    while (true) {} // tiger: event-loop
        \\}
    , &result);
    try std.testing.expectEqual(@as(u32, 0), result.diagnostics);

    try source(&output.writer, "fake-marker.zig",
        \\fn server() void {
        \\    while (true) { const marker = "tiger: event-loop"; }
        \\}
    , &result);
    try std.testing.expectEqual(@as(u32, 1), result.diagnostics);
}

test "declarations close and one-line recursion is rejected" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result = Audit{};

    try source(&output.writer, "declarations.zig",
        \\extern fn write(fd: c_int, buffer: [*]const u8, count: usize) isize;
        \\fn recurse() void { recurse(); }
    , &result);
    try std.testing.expectEqual(@as(u32, 1), result.diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "tiger-style/recursion") != null);
}

test "full file audit rejects long functions and direct recursion" {
    var input = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer input.deinit();
    try input.writer.writeAll("fn too_long() void {\n");
    for (0..69) |_| try input.writer.writeAll("    _ = 0;\n");
    try input.writer.writeAll("}\n");
    try input.writer.writeAll("fn recurse(depth: u32) void {\n");
    try input.writer.writeAll("    if (depth > 0) recurse(depth - 1);\n}\n");

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result = Audit{};
    try source(&output.writer, "invalid.zig", input.written(), &result);
    try std.testing.expectEqual(@as(u32, 2), result.diagnostics);
}
