const std = @import("std");
const output = @import("../output/mod.zig");

pub fn diagnosticQueryJson(allocator: std.mem.Allocator, session_id: []const u8, path: []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeAll("{\"dataset\":\"actuation_runs\",\"where\":[");
    try writer.writeAll("{\"field\":\"session_id\",\"op\":\"eq\",\"value\":");
    try output.writeJsonString(writer, session_id);
    try writer.writeAll("},{\"field\":\"path\",\"op\":\"eq\",\"value\":");
    try output.writeJsonString(writer, path);
    try writer.writeAll("}],\"select\":[\"run_id\",\"session_id\",\"path\",\"true_actuating\",\"verdict\"],\"format\":\"json\"}");
    return writer_alloc.toOwnedSlice();
}

pub fn writeStringArray(writer: anytype, values: []const []u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, idx| {
        if (idx != 0) try writer.writeByte(',');
        try output.writeJsonString(writer, value);
    }
    try writer.writeByte(']');
}
