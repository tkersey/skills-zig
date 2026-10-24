const std = @import("std");
const diagnostic_bytes_max = 16 * 1024;

pub const StderrCapture = struct {
    threaded: std.Io.Threaded,
    vtable: std.Io.VTable,
    diagnostics: [diagnostic_bytes_max]u8 = undefined,
    diagnostic_len: usize = 0,
    overflowed: bool = false,

    pub fn init(allocator: std.mem.Allocator) StderrCapture {
        if (!@import("builtin").is_test) @compileError("StderrCapture is test-only");
        var threaded = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
        var vtable = threaded.io().vtable.*;
        vtable.fileWritePositional = writePositional;
        vtable.operate = operate;
        return .{
            .threaded = threaded,
            .vtable = vtable,
        };
    }

    pub fn deinit(self: *StderrCapture) void {
        self.threaded.deinit();
        const remaining = self.diagnostics[0..self.diagnostic_len];
        if (remaining.len != 0) std.debug.print("{s}", .{remaining});
        if (self.overflowed) {
            std.debug.print("stderr capture exceeded {d} bytes\n", .{diagnostic_bytes_max});
        }
        self.* = undefined;
    }

    pub fn io(self: *StderrCapture) std.Io {
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    pub fn expectEqual(self: *StderrCapture, expected: []const u8) !void {
        if (self.overflowed) return error.DiagnosticCaptureOverflow;
        try std.testing.expectEqualStrings(expected, self.diagnostics[0..self.diagnostic_len]);
        self.diagnostic_len = 0;
    }

    fn fromContext(context: ?*anyopaque) *StderrCapture {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(context.?));
        return @fieldParentPtr("threaded", threaded);
    }

    fn writePositional(
        context: ?*anyopaque,
        file: std.Io.File,
        header: []const u8,
        data: []const []const u8,
        splat: usize,
        offset: u64,
    ) std.Io.File.WritePositionalError!usize {
        if (file.handle == std.Io.File.stderr().handle) return error.Unseekable;
        const native = fromContext(context).threaded.io();
        return native.vtable.fileWritePositional(context, file, header, data, splat, offset);
    }

    fn operate(
        context: ?*anyopaque,
        operation: std.Io.Operation,
    ) std.Io.Cancelable!std.Io.Operation.Result {
        const self = fromContext(context);
        if (operation == .file_write_streaming and
            operation.file_write_streaming.file.handle == std.Io.File.stderr().handle)
        {
            const write = operation.file_write_streaming;
            var writer: std.Io.Writer = .fixed(&self.diagnostics);
            writer.end = self.diagnostic_len;
            defer self.diagnostic_len = writer.end;
            return .{ .file_write_streaming = writer.writeSplatHeader(
                write.header,
                write.data,
                write.splat,
            ) catch blk: {
                self.overflowed = true;
                break :blk error.SystemResources;
            } };
        }
        return self.threaded.io().operate(operation);
    }
};

test "stderr capture preserves supplied file I/O and exact diagnostic batches" {
    var capture = StderrCapture.init(std.testing.allocator);
    defer capture.deinit();
    const io = capture.io();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "ordinary", .data = "file bytes" });
    const bytes = try temporary.dir.readFileAlloc(
        io,
        "ordinary",
        std.testing.allocator,
        .limited(32),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("file bytes", bytes);
    try capture.expectEqual("");
    var stderr = std.Io.File.stderr().writer(io, &.{});
    try stderr.interface.writeAll("first diagnostic\n");
    try stderr.interface.flush();
    try capture.expectEqual("first diagnostic\n");
    try std.Io.File.stderr().writeStreamingAll(io, "second diagnostic\n");
    try capture.expectEqual("second diagnostic\n");
    try capture.expectEqual("");
    const capacity_bytes: [diagnostic_bytes_max]u8 = @splat('x');
    try std.Io.File.stderr().writeStreamingAll(io, &capacity_bytes);
    try capture.expectEqual(&capacity_bytes);
}
