var benchmark_url: []const u8 = undefined;

fn benchmarkHttp() !Http {
    if (comptime @hasDecl(Http, "init")) return Http.init(std.testing.allocator, std.testing.io);
    return .{};
}

fn benchmarkDeinit(http: *Http) void {
    if (comptime @hasDecl(Http, "deinit")) http.deinit();
}

fn benchmarkSequence() !void {
    var http = try benchmarkHttp();
    defer benchmarkDeinit(&http);
    const requests = [_]Request{
        .{ .token = "synthetic-secret" },
        .discovery,
        .{ .keys = "https://auth.openai.com/keys" },
    };
    for (requests) |request_value| {
        var response = try http.transport().request(
            std.testing.allocator,
            std.testing.io,
            request_value,
        );
        defer response.deinit();
        try std.testing.expectEqualStrings("synthetic-secret", response.body);
    }
}

fn benchmarkRound(round: usize) !void {
    var fixture = try HttpTestServer.open(&.{ .{}, .{}, .{} });
    defer fixture.server.deinit(std.testing.io);
    var url_buffer: [64]u8 = undefined;
    benchmark_url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/test", .{
        fixture.server.socket.address.getPort(),
    });
    var worker = try std.testing.io.concurrent(HttpTestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    try benchmarkSequence();
    const elapsed = std.Io.Clock.awake.now(std.testing.io).nanoseconds - start;
    try worker.await(std.testing.io);
    std.debug.print("{{\"round\":{d},\"requests\":3,\"connections\":{d},\"elapsed_ns\":{d}}}\n", .{
        round, fixture.connections, elapsed,
    });
}

test "transport performance synthetic login sequence" {
    for (0..25) |round| try benchmarkRound(round);
}
