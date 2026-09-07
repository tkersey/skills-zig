const std = @import("std");
const json = @import("json.zig");

pub const Diagnostic = struct {
    code: []u8,
    path: []u8,
    message: []u8,

    fn clone(
        allocator: std.mem.Allocator,
        code: []const u8,
        path: []const u8,
        message: []const u8,
    ) !Diagnostic {
        const owned_code = try allocator.dupe(u8, code);
        errdefer allocator.free(owned_code);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        return .{
            .code = owned_code,
            .path = owned_path,
            .message = try allocator.dupe(u8, message),
        };
    }

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
        const bounded_message = utf8Prefix(message, self.limits.max_message_bytes);
        const metadata_bytes = std.math.add(usize, code.len, path.len) catch {
            self.truncated = true;
            return;
        };
        const added = std.math.add(
            usize,
            metadata_bytes,
            bounded_message.len,
        ) catch {
            self.truncated = true;
            return;
        };
        if (added > self.limits.max_total_bytes -| self.total_bytes) {
            self.truncated = true;
            return;
        }
        var owned = try Diagnostic.clone(self.allocator, code, path, bounded_message);
        errdefer owned.deinit(self.allocator);
        try self.items.append(self.allocator, owned);
        self.total_bytes += added;
        if (bounded_message.len != message.len) self.truncated = true;
    }
};

fn utf8Prefix(text: []const u8, maximum: usize) []const u8 {
    var end = @min(text.len, maximum);
    if (end == text.len) return text;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

fn addForAllocationFailure(allocator: std.mem.Allocator) !void {
    var collector = Collector.init(allocator, .{});
    defer collector.deinit();
    try collector.add("initial", "/", "first");
    const prior_bytes = collector.total_bytes;
    collector.add("next", "/second", "second") catch |err| {
        try std.testing.expectEqual(@as(usize, 1), collector.items.items.len);
        try std.testing.expectEqual(prior_bytes, collector.total_bytes);
        try std.testing.expect(!collector.truncated);
        try std.testing.expectEqualStrings("initial", collector.items.items[0].code);
        return err;
    };
}

test "diagnostic admission remains unchanged and leak free after allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        addForAllocationFailure,
        .{},
    );
}

test "bounded diagnostic messages end on UTF-8 boundaries" {
    const message = "a\xc3\xa9\xf0\x9f\x98\x80z";
    for (0..message.len + 1) |maximum| {
        var collector = Collector.init(std.testing.allocator, .{ .max_message_bytes = maximum });
        defer collector.deinit();
        try collector.add("valid", "/", message);
        const bounded = collector.items.items[0].message;
        try std.testing.expect(bounded.len <= maximum);
        try std.testing.expect(std.unicode.utf8ValidateSlice(bounded));
        try std.testing.expect(std.mem.startsWith(u8, message, bounded));
        try std.testing.expectEqual(maximum < message.len, collector.truncated);
    }
}

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
