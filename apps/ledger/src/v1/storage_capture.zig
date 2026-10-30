const std = @import("std");

pub const Result = struct {
    bytes: u64,
    sha256: [32]u8,
};

pub fn copy(
    reader: *std.Io.Reader,
    staging: *std.Io.Writer,
    max_bytes: u64,
    scratch: []u8,
) !Result {
    if (scratch.len == 0) return error.EmptyCaptureBuffer;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var consumed: u64 = 0;
    while (consumed < max_bytes) {
        const remaining = max_bytes - consumed;
        const capacity: usize = @intCast(@min(remaining, scratch.len));
        const count = try reader.readSliceShort(scratch[0..capacity]);
        if (count == 0) break;
        try staging.writeAll(scratch[0..count]);
        hash.update(scratch[0..count]);
        consumed += count;
    }
    if (consumed == max_bytes) {
        var overflow: [1]u8 = undefined;
        if (try reader.readSliceShort(&overflow) != 0) {
            return error.CaptureLimitExceeded;
        }
    }
    try staging.flush();
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .bytes = consumed, .sha256 = digest };
}

test "capture counts and hashes the exact staged stream across chunk boundaries" {
    const payload = "a bounded capture spanning several chunks";
    for (1..payload.len + 2) |size| {
        var reader = std.Io.Reader.fixed(payload);
        var destination: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&destination);
        var scratch: [128]u8 = undefined;
        const captured = try copy(&reader, &writer, payload.len, scratch[0..size]);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
        try std.testing.expectEqual(payload.len, captured.bytes);
        try std.testing.expectEqualSlices(u8, &digest, &captured.sha256);
        try std.testing.expectEqualStrings(payload, writer.buffered());
    }
}

test "capture limit never writes overflow bytes including zero capacity" {
    const payload = "abcdef";
    for (0..payload.len) |limit| {
        var reader = std.Io.Reader.fixed(payload);
        var destination: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&destination);
        var scratch: [3]u8 = undefined;
        try std.testing.expectError(
            error.CaptureLimitExceeded,
            copy(&reader, &writer, limit, &scratch),
        );
        try std.testing.expectEqualStrings(payload[0..limit], writer.buffered());
    }
}

test "empty capture and maximal integer limit preserve exact length" {
    for ([_]u64{ 0, 1, std.math.maxInt(u64) }) |limit| {
        var reader = std.Io.Reader.fixed("");
        var writer = std.Io.Writer.fixed(&.{});
        var scratch: [1]u8 = undefined;
        const result = try copy(&reader, &writer, limit, &scratch);
        try std.testing.expectEqual(0, result.bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("", &digest, .{});
        try std.testing.expectEqualSlices(u8, &digest, &result.sha256);
    }
}

test "capture does not return an accepted descriptor on staging failure" {
    var reader = std.Io.Reader.fixed("abcdef");
    var destination: [2]u8 = undefined;
    var writer = std.Io.Writer.fixed(&destination);
    var scratch: [3]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, copy(&reader, &writer, 6, &scratch));
}

test "capture measures file growth and truncation after initial observation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_][]const u8{ "longer than the initial file", "" }) |payload| {
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "input", .data = "old" });
        const file = try temporary.dir.openFile(std.testing.io, "input", .{});
        defer file.close(std.testing.io);
        const before = try file.stat(std.testing.io);
        try std.testing.expectEqual(3, before.size);
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "input", .data = payload });
        var reader = file.reader(std.testing.io, &.{});
        var destination: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&destination);
        var scratch: [4]u8 = undefined;
        const captured = try copy(&reader.interface, &writer, destination.len, &scratch);
        try std.testing.expectEqual(payload.len, captured.bytes);
        try std.testing.expectEqualStrings(payload, writer.buffered());
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
        try std.testing.expectEqualSlices(u8, &digest, &captured.sha256);
    }
}
