const FramingBenchmark = struct {
    input: []const u8,
    offset: usize = 0,
    reads: usize = 0,
    positional: usize = 0,

    fn readPositional(
        userdata: ?*anyopaque,
        _: std.Io.File,
        _: []const []u8,
        _: u64,
    ) std.Io.File.ReadPositionalError!usize {
        const self: *@This() = @ptrCast(@alignCast(userdata.?));
        self.positional += 1;
        return error.Unseekable;
    }

    fn operate(
        userdata: ?*anyopaque,
        operation: std.Io.Operation,
    ) std.Io.Cancelable!std.Io.Operation.Result {
        const self: *@This() = @ptrCast(@alignCast(userdata.?));
        if (operation != .file_read_streaming) return error.Canceled;
        self.reads += 1;
        if (self.offset == self.input.len) return .{ .file_read_streaming = error.EndOfStream };
        const output = operation.file_read_streaming.data[0];
        const count = @min(output.len, self.input.len - self.offset);
        @memcpy(output[0..count], self.input[self.offset..][0..count]);
        self.offset += count;
        return .{ .file_read_streaming = count };
    }
};

test "framing benchmark synthetic transport" {
    const allocator = std.testing.allocator;
    const clock_io = std.testing.io;
    for ([_]usize{ 1024, 65536, 1048576 }) |size| {
        const input = try allocator.alloc(u8, size);
        defer allocator.free(input);
        @memset(input, 'x');
        input[size - 1] = '\n';
        for (0..7) |round| {
            var source = FramingBenchmark{ .input = input };
            var vtable = std.Io.failing.vtable.*;
            vtable.operate = FramingBenchmark.operate;
            vtable.fileReadPositional = FramingBenchmark.readPositional;
            var allocations = @import("core_perf").CountingAllocator.init(allocator);
            var client = serverRequestTestClient();
            client.allocator = allocations.allocator();
            client.io = .{ .userdata = &source, .vtable = &vtable };
            client.stdout_file = .{ .handle = 123, .flags = .{ .nonblocking = false } };
            defer client.deinit();
            const begin = std.Io.Clock.awake.now(clock_io);
            const line = (try client.readLineAlloc()).?;
            const elapsed = begin.durationTo(std.Io.Clock.awake.now(clock_io)).nanoseconds;
            defer allocations.allocator().free(line);
            try std.testing.expectEqualSlices(u8, input[0 .. size - 1], line);
            std.debug.print(
                "FRAMING size={d} round={d} ns={d} reads={d} positional={d} " ++
                    "allocations={d} requested_bytes={d}\n",
                .{
                    size,
                    round,
                    elapsed,
                    source.reads,
                    source.positional,
                    allocations.stats.totalCalls(),
                    allocations.stats.totalRequestedBytes(),
                },
            );
        }
    }
}
