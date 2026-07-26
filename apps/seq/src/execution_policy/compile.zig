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

const compiler_contract_name = "execution-policy-compiler";
const compiler_contract_version = "v1";

pub fn compileToJson(allocator: std.mem.Allocator, bytes: []const u8) !Report {
    var rejected_source_digest = sourceDigest(allocator, bytes) catch null;
    defer if (rejected_source_digest) |*digest| digest.deinit(allocator);
    var result = try execution_policy_core.compilePolicy(allocator, bytes);
    defer result.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(
        "{\n  \"execution_policy_compile\": {\n" ++
            "    \"compiler_contract\": {\"name\": \"" ++
            compiler_contract_name ++
            "\", \"version\": \"" ++
            compiler_contract_version ++
            "\"},\n    \"compiled\": ",
    );
    switch (result) {
        .policy => |policy| {
            try writer.writeAll("true,\n    \"source_policy_digest\": ");
            try writeJsonString(writer, policy.digest());
            try writer.writeAll(",\n    \"errors\": []\n");
            try writer.writeAll("  }\n}\n");
            return .{ .json = try out.toOwnedSlice(), .compiled = true };
        },
        .report => |report| {
            try writer.writeAll("false,\n    \"source_policy_digest\": ");
            if (rejected_source_digest) |digest| {
                try writeJsonString(writer, digest.text);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\n    \"errors\": [");
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

fn sourceDigest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !execution_policy_core.Digest {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{},
    );
    defer parsed.deinit();
    var source = parsed.value;
    if (source == .object and source.object.count() == 1) {
        if (source.object.get("execution_policy_graph")) |wrapped| {
            if (wrapped == .object) source = wrapped;
        }
    }
    const canonical = try execution_policy_core.canonical_json
        .canonicalizeValueAlloc(allocator, source);
    defer allocator.free(canonical);
    return execution_policy_core.canonical_json.digestRawJson(
        allocator,
        canonical,
    );
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

test "compile report exposes contract source digest and errors" {
    var report = try compileToJson(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":[],
        \\"actions":[{"id":"a"}],"policy_rules":[{"id":"r","actions":["a"]}]}
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.compiled);
    try std.testing.expect(
        std.mem.indexOf(u8, report.json, "\"compiled\": true") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            report.json,
            "\"compiler_contract\": {\"name\": \"execution-policy-compiler\", \"version\": \"v1\"}",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            report.json,
            "\"source_policy_digest\": \"sha256:",
        ) != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, report.json, "runtime_") == null);
}

test "compile report retains structured rejection paths" {
    var report = try compileToJson(std.testing.allocator, "{}");
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.compiled);
    try std.testing.expect(
        std.mem.indexOf(u8, report.json, "\"code\": \"schema_invalid\"") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, report.json, "\"path\": \"$.policy_id\"") != null);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            report.json,
            "\"source_policy_digest\": \"sha256:",
        ) != null,
    );
}

test "unparseable rejection cannot claim a source digest" {
    var report = try compileToJson(std.testing.allocator, "{");
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.compiled);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            report.json,
            "\"source_policy_digest\": null",
        ) != null,
    );
}
