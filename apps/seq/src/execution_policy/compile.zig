const std = @import("std");
const execution_policy_core = @import("execution_policy_core");

pub const Report = struct {
    json: []u8,
    compiled: bool,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
        self.* = undefined;
    }
};

pub fn compileToJson(allocator: std.mem.Allocator, bytes: []const u8) !Report {
    var result = try execution_policy_core.compilePolicy(allocator, bytes);
    defer result.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\n  \"execution_policy_compile\": {\n    \"compiled\": ");
    switch (result) {
        .policy => |policy| {
            try writer.writeAll("true,\n    \"policy_digest\": ");
            try writeJsonString(writer, policy.digest());
            try writer.writeAll(",\n    \"errors\": []\n");
            try writer.writeAll("  }\n}\n");
            return .{ .json = try out.toOwnedSlice(), .compiled = true };
        },
        .report => |report| {
            try writer.writeAll("false,\n    \"policy_digest\": null,\n    \"errors\": [");
            for (report.errors, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try writer.writeAll("\n      {\"code\": ");
                try writeJsonString(writer, @tagName(item.code));
                try writer.writeAll(", \"path\": ");
                try writeJsonString(writer, item.path);
                try writer.writeByte('}');
            }
            if (report.errors.len > 0) try writer.writeByte('\n');
            try writer.writeAll("    ]\n  }\n}\n");
            return .{ .json = try out.toOwnedSlice(), .compiled = false };
        },
    }
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

test "compile report exposes only source digest and errors" {
    var report = try compileToJson(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":[],"actions":[{"id":"a"}],"policy_rules":[{"id":"r","actions":["a"]}]}
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.compiled);
    try std.testing.expect(std.mem.indexOf(u8, report.json, "\"compiled\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.json, "\"policy_digest\": \"sha256:") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.json, "runtime_") == null);
}

test "compile report retains structured rejection paths" {
    var report = try compileToJson(std.testing.allocator, "{}");
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.compiled);
    try std.testing.expect(std.mem.indexOf(u8, report.json, "\"code\": \"schema_invalid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.json, "\"path\": \"$.policy_id\"") != null);
}
