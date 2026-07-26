const std = @import("std");
const json = @import("json.zig");

pub const Diagnostic = struct {
    code: []u8,
    path: []u8,
    message: []u8,

    fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const Limits = struct {
    max_count: usize = 64,
    max_total_bytes: usize = 64 * 1024,
    max_message_bytes: usize = 2048,
};

pub const Collector = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    items: std.ArrayList(Diagnostic) = .empty,
    total_bytes: usize = 0,
    truncated: bool = false,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Collector {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *Collector) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(
        self: *Collector,
        code: []const u8,
        path: []const u8,
        message: []const u8,
    ) !void {
        try json.safeIdentifier(code, 128);
        if (!std.unicode.utf8ValidateSlice(path) or !std.unicode.utf8ValidateSlice(message)) {
            return error.InvalidDiagnosticUtf8;
        }
        if (self.items.items.len >= self.limits.max_count) {
            self.truncated = true;
            return;
        }
        const bounded_message = message[0..@min(message.len, self.limits.max_message_bytes)];
        const added = std.math.add(
            usize,
            code.len + path.len,
            bounded_message.len,
        ) catch {
            self.truncated = true;
            return;
        };
        if (added > self.limits.max_total_bytes -| self.total_bytes) {
            self.truncated = true;
            return;
        }
        try self.items.append(self.allocator, .{
            .code = try self.allocator.dupe(u8, code),
            .path = try self.allocator.dupe(u8, path),
            .message = try self.allocator.dupe(u8, bounded_message),
        });
        self.total_bytes += added;
        if (bounded_message.len != message.len) self.truncated = true;
    }
};

test "diagnostics are bounded and stable-code only" {
    var collector = Collector.init(std.testing.allocator, .{
        .max_count = 1,
        .max_total_bytes = 32,
        .max_message_bytes = 8,
    });
    defer collector.deinit();
    try collector.add("definition.invalid", "/schema", "long diagnostic message");
    try collector.add("definition.second", "/schema", "ignored");
    try std.testing.expectEqual(@as(usize, 1), collector.items.items.len);
    try std.testing.expect(collector.truncated);
    try std.testing.expectError(
        error.InvalidIdentifier,
        collector.add("bad code", "", ""),
    );
}
