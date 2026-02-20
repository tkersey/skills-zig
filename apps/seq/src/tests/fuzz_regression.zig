const std = @import("std");
const lib = @import("../lib.zig");

fn fuzzParseCommand(_: void, input: []const u8) !void {
    _ = lib.parseCommand(input);
}

test "fuzz corpus parseCommand regression seeds" {
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, "testdata/fuzz/parse-command.txt", 64 * 1024);
    defer std.testing.allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const seed = std.mem.trim(u8, line, " \t\r\n");
        if (seed.len == 0) continue;
        _ = lib.parseCommand(seed);
    }
}

test "fuzz parseCommand total over arbitrary input" {
    try std.testing.fuzz({}, fuzzParseCommand, .{});
}
