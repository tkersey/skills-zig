const std = @import("std");
const lib = @import("../lib.zig");

fn fuzzParseCommand(_: void, smith: *std.testing.Smith) !void {
    var storage: [256]u8 = undefined;
    for (&storage) |*b| b.* = smith.value(u8);
    const len = smith.value(usize) % (storage.len + 1);
    const input = storage[0..len];
    _ = lib.parseCommand(input);
}

test "fuzz corpus parseCommand regression seeds" {
    const content = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "testdata/fuzz/parse-command.txt", std.testing.allocator, .limited(64 * 1024));
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
