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

pub fn countFile(audit: *Audit) !void {
    if (audit.files == limits.files_max) return error.FileLimitExceeded;
    audit.files += 1;
}

pub fn file(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    writer: anytype,
    path: []const u8,
    audit: *Audit,
    count_file: bool,
) !void {
    if (count_file) try countFile(audit);
    const input = try dir.readFileAlloc(
        io,
        path,
        allocator,
        .limited(limits.file_bytes_max),
    );
    defer allocator.free(input);

    try source(allocator, writer, path, input, audit);
}

test "file auditing uses the supplied directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "supplied.zig",
        .data = "fn run() void { while (true) {} }\n",
    });
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var audit = Audit{};
    try file(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        &output.writer,
        "supplied.zig",
        &audit,
        true,
    );
    try std.testing.expectEqual(@as(u32, 1), audit.files);
    try std.testing.expectEqual(@as(u32, 1), audit.diagnostics);
    try std.testing.expect(std.mem.startsWith(u8, output.written(), "supplied.zig:1:"));
}

pub fn source(
    allocator: std.mem.Allocator,
    writer: anytype,
    path: []const u8,
    input: []const u8,
    audit: *Audit,
) !void {
    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, input, '\n');

    while (lines.next()) |source_line| {
        if (line_number == limits.lines_per_file_max) return error.LineLimitExceeded;
        line_number += 1;
        audit.lines += 1;
        try line(writer, path, line_number, source_line, audit);
    }

    try @import("structure.zig").run(allocator, writer, path, input, audit);
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
    var content_start: usize = 0;
    while (content_start < source_line.len and
        source_line[content_start] == ' ') : (content_start += 1)
    {}
    const trimmed = source_line[content_start..];
    const is_multiline_data = std.mem.startsWith(u8, trimmed, "\\\\");
    if (source_line.len > limits.line_columns_max and !is_multiline_data) {
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

test "line audit covers expected and unexpected space" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result = Audit{};

    try source(std.testing.allocator, &output.writer, "valid.zig",
        \\fn bounded() void {
        \\    var index: u32 = 0;
        \\    while (index < 2) : (index += 1) {}
        \\}
    , &result);
    try std.testing.expectEqual(@as(u32, 0), result.diagnostics);

    try source(std.testing.allocator, &output.writer, "invalid.zig",
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

    try source(
        std.testing.allocator,
        &output.writer,
        "strings.zig",
        \\fn server() void {
        \\    const example = "while (true) catch {}";
        \\    const data =
        \\    \\{"passive_definition":"compact machine data is exempt from source layout width because it is not executable Zig"}
        \\    ;
        \\    _ = data;
        \\    _ = example;
        \\    while (true) {} // tiger: event-loop
        \\}
    ,
        &result,
    );
    try std.testing.expectEqual(@as(u32, 0), result.diagnostics);

    try source(std.testing.allocator, &output.writer, "fake-marker.zig",
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

    try source(std.testing.allocator, &output.writer, "declarations.zig",
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
    try source(std.testing.allocator, &output.writer, "invalid.zig", input.written(), &result);
    try std.testing.expectEqual(@as(u32, 2), result.diagnostics);
}

test "receiver recursion is rejected across multiline declarations and calls" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result = Audit{};
    try source(std.testing.allocator, &output.writer, "receiver.zig",
        \\fn visit(
        \\    self: *Builder,
        \\    child: Child,
        \\) !void {
        \\    try self.visit(
        \\        child,
        \\    );
        \\}
        \\fn run(self: *Runner) void { other.run(); }
        \\fn get(map: *Map) void { map.get(); }
        \\fn run(other: *Other, self: *Runner) void { self.run(); }
    , &result);
    try std.testing.expectEqual(@as(u32, 1), result.diagnostics);
}

test "receiver recursion is rejected with comptime and noalias parameters" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result = Audit{};
    try source(std.testing.allocator, &output.writer, "modifiers.zig",
        \\fn visit(comptime self: Builder) void { self.visit(); }
        \\fn walk(
        \\    noalias self: *Builder,
        \\) void {
        \\    self.walk();
        \\}
        \\fn run(
        \\    comptime T: type,
        \\    self: *Runner,
        \\) void {
        \\    self.run();
        \\}
    , &result);
    try std.testing.expectEqual(@as(u32, 2), result.diagnostics);
}

test "generic factories and nested methods have independent structural limits" {
    var input = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer input.deinit();
    try input.writer.writeAll("fn Factory(comptime T: type) type {\nreturn struct {\n");
    for (0..3) |i| {
        try input.writer.print("fn method{d}() void {{\n", .{i});
        for (0..38) |_| try input.writer.writeAll("_ = Factory(u8);\n");
        try input.writer.writeAll("}\n");
    }
    try input.writer.writeAll("};\n}\n");
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result: Audit = .{};
    try source(std.testing.allocator, &output.writer, "factory.zig", input.written(), &result);
    try std.testing.expectEqual(@as(u32, 0), result.diagnostics);
}

test "nested methods cannot conceal excessive length or runtime recursion" {
    var input = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer input.deinit();
    try input.writer.writeAll("fn Factory(comptime T: type) type {\nreturn struct {\n");
    try input.writer.writeAll("fn large() void {\n");
    for (0..69) |_| try input.writer.writeAll("_ = 0;\n");
    try input.writer.writeAll("}\nfn walk(self: *@This()) void { self.walk(); }\n};\n}\n");
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result: Audit = .{};
    try source(std.testing.allocator, &output.writer, "factory.zig", input.written(), &result);
    try std.testing.expectEqual(@as(u32, 2), result.diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "function-length") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "recursion") != null);
}

test "multiline calls and nested declaration signatures retain their actual owner" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result: Audit = .{};
    try source(std.testing.allocator, &output.writer, "owners.zig",
        \\fn Outer(comptime T: type) type {
        \\    return struct {
        \\        fn create() Outer(u8) { return undefined; }
        \\        fn run(self: *@This()) void {
        \\            self
        \\                .run();
        \\        }
        \\    };
        \\}
        \\fn normal() void { const S = struct { fn normal() void {} }; _ = S; normal(); }
    , &result);
    try std.testing.expectEqual(@as(u32, 2), result.diagnostics);
}

test "whole file syntax errors cannot pass structural auditing" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result: Audit = .{};
    try source(
        std.testing.allocator,
        &output.writer,
        "syntax.zig",
        "fn incomplete() void {",
        &result,
    );
    try std.testing.expectEqual(@as(u32, 1), result.diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "tiger-style/syntax") != null);
}

test "mandatory inline expansion has no native frame and nested functions remain checked" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result: Audit = .{};
    try source(std.testing.allocator, &output.writer, "inline.zig",
        \\inline fn descend(comptime T: type, value: T) usize {
        \\    return switch (@typeInfo(T)) {
        \\        .optional => |info| if (value) |item| descend(info.child, item) else 0,
        \\        else => 1,
        \\    };
        \\}
        \\inline fn outer() void {
        \\    const S = struct { fn run() void { run(); } };
        \\    _ = S;
        \\}
        \\noinline fn direct() void { direct(); }
    , &result);
    try std.testing.expectEqual(@as(u32, 2), result.diagnostics);
}

fn structuralAllocationFailure(allocator: std.mem.Allocator) !void {
    var bytes: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var result: Audit = .{};
    try source(allocator, &output, "allocation.zig",
        \\fn Outer(comptime T: type) type {
        \\    return struct { fn run(self: *@This()) void { self.run(); } };
        \\}
    , &result);
    try std.testing.expectEqual(@as(u32, 1), result.diagnostics);
}

test "structural audit releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        structuralAllocationFailure,
        .{},
    );
}

test "structural diagnostic output failure propagates" {
    var output = std.Io.Writer.fixed(&.{});
    var result: Audit = .{};
    try std.testing.expectError(error.WriteFailed, source(
        std.testing.allocator,
        &output,
        "output.zig",
        "fn recursive() void { recursive(); }",
        &result,
    ));
}

test "shared nested declaration lines retain enclosing code at the length boundary" {
    for ([_]usize{ 68, 69 }) |count| {
        var input = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer input.deinit();
        try input.writer.writeAll("fn outer() void {\n");
        for (0..count) |_| {
            try input.writer.writeAll("_ = struct { fn inner() void {} };\n");
        }
        try input.writer.writeAll("}\n");
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var result: Audit = .{};
        try source(std.testing.allocator, &output.writer, "shared.zig", input.written(), &result);
        try std.testing.expectEqual(@as(u32, @intFromBool(count == 69)), result.diagnostics);
    }
}

test "sibling declarations sharing lines do not become enclosing code" {
    var input = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer input.deinit();
    try input.writer.writeAll("fn Factory() type {\nreturn struct {\n");
    for (0..69) |index| {
        try input.writer.print("fn a{d}() void {{}} fn b{d}() void {{}}\n", .{ index, index });
    }
    try input.writer.writeAll("};\n}\n");
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result: Audit = .{};
    try source(std.testing.allocator, &output.writer, "siblings.zig", input.written(), &result);
    try std.testing.expectEqual(@as(u32, 0), result.diagnostics);
}

test "blank physical lines retain their containing function" {
    for ([_]usize{ 68, 69 }) |count| {
        var input = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer input.deinit();
        try input.writer.writeAll("fn outer() void {\n");
        for (0..count) |_| try input.writer.writeAll("\n");
        try input.writer.writeAll("}\n");
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var result: Audit = .{};
        try source(std.testing.allocator, &output.writer, "blank.zig", input.written(), &result);
        try std.testing.expectEqual(@as(u32, @intFromBool(count == 69)), result.diagnostics);
    }
}

test "optional and error-wrapped type results remain compiler-only" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var result: Audit = .{};
    try source(std.testing.allocator, &output.writer, "results.zig",
        \\fn errors(comptime n: usize) error{NoType}!type {
        \\    if (n == 0) return u8;
        \\    return try errors(n - 1);
        \\}
        \\fn optional(comptime n: usize) ?type {
        \\    if (n == 0) return u8;
        \\    return optional(n - 1);
        \\}
        \\fn grouped(comptime n: usize) (error{NoType}!(?type)) {
        \\    if (n == 0) return u8;
        \\    return try grouped(n - 1);
        \\}
        \\fn runtime(n: usize) error{Bad}!?u8 { return try runtime(n); }
        \\fn another(n: usize) (?u8) { return another(n); }
    , &result);
    try std.testing.expectEqual(@as(u32, 2), result.diagnostics);
}
