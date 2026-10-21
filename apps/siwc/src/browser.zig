const std = @import("std");
const builtin = @import("builtin");

const launch_timeout_ms = 10_000;
const Outcome = union(enum) { launch: anyerror!void, timeout: std.Io.Cancelable!void };

pub fn open(io: std.Io, url: []const u8) !void {
    var results: [2]Outcome = undefined;
    var select = std.Io.Select(Outcome).init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.launch, launch, .{ io, url });
    try select.concurrent(.timeout, timeout, .{io});
    switch (try select.await()) {
        .launch => |result| try result,
        .timeout => |result| {
            try result;
            return error.BrowserLaunchTimedOut;
        },
    }
}

fn timeout(io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(launch_timeout_ms), .awake);
}

fn launch(io: std.Io, url: []const u8) !void {
    const executable = switch (builtin.os.tag) {
        .macos => "/usr/bin/open",
        .linux => "xdg-open",
        else => return error.UnsupportedPlatform,
    };
    var child = try std.process.spawn(io, .{
        .argv = &.{ executable, url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.BrowserLaunchFailed,
        else => return error.BrowserLaunchFailed,
    }
}
