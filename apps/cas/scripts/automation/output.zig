const std = @import("std");

pub fn userErrorFmt(comptime fmt: []const u8, args: anytype) error{UserInput} {
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stderr = &stderr_writer.interface;
    _ = stderr.print("error: " ++ fmt ++ "\n", args) catch {};
    return error.UserInput;
}

pub fn jsonWriteString(writer: anytype, value: []const u8) !void {
    var out = writer;
    try out.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try out.writeAll("\\\\"),
            '"' => try out.writeAll("\\\""),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try out.print("\\u{X:0>4}", .{@as(u16, ch)});
                } else {
                    try out.writeByte(ch);
                }
            },
        }
    }
    try out.writeByte('"');
}

pub fn xmlEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;

    for (value) |ch| {
        switch (ch) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&apos;"),
            else => try w.writeByte(ch),
        }
    }

    return writer_alloc.toOwnedSlice();
}

pub fn tomlQuoteAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try w.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(ch),
        }
    }
    try w.writeByte('"');

    return writer_alloc.toOwnedSlice();
}

pub fn renderTomlStringArray(allocator: std.mem.Allocator, values: []const []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try w.writeByte('[');
    for (values, 0..) |value, idx| {
        if (idx > 0) try w.writeAll(", ");
        const quoted = try tomlQuoteAlloc(allocator, value);
        defer allocator.free(quoted);
        try w.writeAll(quoted);
    }
    try w.writeByte(']');

    return writer_alloc.toOwnedSlice();
}

pub fn writeFileAtomic(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds });
    defer allocator.free(tmp);

    {
        var file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), tmp, .{}) catch |err| {
            return userErrorFmt("unable to create temp file ({s}): {s}", .{ tmp, @errorName(err) });
        };
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), contents) catch |err| {
            return userErrorFmt("unable to write temp file ({s}): {s}", .{ tmp, @errorName(err) });
        };
    }

    std.Io.Dir.renameAbsolute(tmp, path, std.Io.Threaded.global_single_threaded.io()) catch |err| {
        return userErrorFmt("unable to move temp file to target ({s}): {s}", .{ path, @errorName(err) });
    };
}

pub fn printAutomationRowsJson(stdout: anytype, rows: anytype) !void {
    try stdout.writeAll("[\n");
    for (rows, 0..) |row, idx| {
        try printAutomationRowJson(stdout, row, 2, false);
        if (idx + 1 != rows.len) {
            try stdout.writeAll(",\n");
        } else {
            try stdout.writeByte('\n');
        }
    }
    try stdout.writeAll("]\n");
}

pub fn buildAutomationRowsJsonAlloc(allocator: std.mem.Allocator, rows: anytype) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try printAutomationRowsJson(w, rows);
    return writer_alloc.toOwnedSlice();
}

pub fn buildAutomationRowJsonAlloc(allocator: std.mem.Allocator, row: anytype) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try printAutomationRowJson(w, row, 0, false);
    try w.writeByte('\n');
    return writer_alloc.toOwnedSlice();
}

pub fn printAutomationRowJson(stdout: anytype, row: anytype, indent: usize, trailing_comma: bool) !void {
    const pad = "                                ";
    const prefix = pad[0..@min(indent, pad.len)];
    const field = pad[0..@min(indent + 2, pad.len)];

    try stdout.print("{s}{{\n", .{prefix});
    try stdout.print("{s}\"created_at\": {d},\n", .{ field, row.created_at });
    try stdout.print("{s}\"cwds\": ", .{field});
    try jsonWriteString(stdout, row.cwds_json);
    try stdout.writeAll(",\n");
    try stdout.print("{s}\"id\": ", .{field});
    try jsonWriteString(stdout, row.id);
    try stdout.writeAll(",\n");
    if (row.last_run_at) |value| {
        try stdout.print("{s}\"last_run_at\": {d},\n", .{ field, value });
    } else {
        try stdout.print("{s}\"last_run_at\": null,\n", .{field});
    }
    try stdout.print("{s}\"name\": ", .{field});
    try jsonWriteString(stdout, row.name);
    try stdout.writeAll(",\n");
    if (row.next_run_at) |value| {
        try stdout.print("{s}\"next_run_at\": {d},\n", .{ field, value });
    } else {
        try stdout.print("{s}\"next_run_at\": null,\n", .{field});
    }
    try stdout.print("{s}\"prompt\": ", .{field});
    try jsonWriteString(stdout, row.prompt);
    try stdout.writeAll(",\n");
    try stdout.print("{s}\"rrule\": ", .{field});
    try jsonWriteString(stdout, row.rrule);
    try stdout.writeAll(",\n");
    try stdout.print("{s}\"status\": ", .{field});
    try jsonWriteString(stdout, row.status);
    try stdout.writeAll(",\n");
    try stdout.print("{s}\"updated_at\": {d}\n", .{ field, row.updated_at });
    try stdout.print("{s}}}", .{prefix});
    if (trailing_comma) try stdout.writeByte(',');
}

pub fn printRunResultsJson(stdout: anytype, results: anytype) !void {
    try stdout.writeAll("[\n");
    for (results, 0..) |item, idx| {
        try stdout.writeAll("  {\n");
        try stdout.writeAll("    \"id\": ");
        try jsonWriteString(stdout, item.id);
        try stdout.writeAll(",\n    \"status\": ");
        try jsonWriteString(stdout, item.status);
        try stdout.writeAll(",\n    \"thread_id\": ");
        try jsonWriteString(stdout, item.thread_id);
        try stdout.writeAll(",\n    \"cwd\": ");
        try jsonWriteString(stdout, item.cwd);
        if (item.next_run_at) |value| {
            try stdout.print(",\n    \"next_run_at\": {d}", .{value});
        } else {
            try stdout.writeAll(",\n    \"next_run_at\": null");
        }
        if (item.exit_code) |code| {
            try stdout.print(",\n    \"exit_code\": {d}", .{code});
        } else {
            try stdout.writeAll(",\n    \"exit_code\": null");
        }
        if (item.err) |err_text| {
            try stdout.writeAll(",\n    \"error\": ");
            try jsonWriteString(stdout, err_text);
        }
        try stdout.writeAll("\n  }");
        if (idx + 1 != results.len) try stdout.writeAll(",\n") else try stdout.writeByte('\n');
    }
    try stdout.writeAll("]\n");
}

pub fn buildRunResultsJsonAlloc(allocator: std.mem.Allocator, results: anytype) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try printRunResultsJson(w, results);
    return writer_alloc.toOwnedSlice();
}
