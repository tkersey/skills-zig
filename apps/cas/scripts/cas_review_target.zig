//! Private review target variants and compatibility with existing wire records.
const std = @import("std");
const core_json = @import("core_json");

/// Payloads belong only to their selected target. Git resolution and currentness
/// remain operation-time checks in the review controller.
/// Slices borrow argv, a parsed record, or the controller's canonical target;
/// these conversions never extend that owner's lifetime.
pub const ReviewTarget = union(enum) {
    uncommitted,
    base_branch: []const u8,
    commit: struct {
        sha: []const u8,
        title: ?[]const u8 = null,
    },
};

pub const TargetRecord = struct {
    type: []const u8,
    branch: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

pub fn fromRecord(record: TargetRecord) !ReviewTarget {
    if (std.mem.eql(u8, record.type, "uncommittedChanges")) {
        if (record.branch != null or record.sha != null or record.title != null) {
            return error.InvalidSessionTarget;
        }
        return .uncommitted;
    }
    if (std.mem.eql(u8, record.type, "baseBranch")) {
        const branch = record.branch orelse return error.InvalidSessionTarget;
        if (branch.len == 0 or record.sha != null or record.title != null) {
            return error.InvalidSessionTarget;
        }
        return .{ .base_branch = branch };
    }
    if (std.mem.eql(u8, record.type, "commit")) {
        const sha = record.sha orelse return error.InvalidSessionTarget;
        if (sha.len == 0 or record.branch != null) return error.InvalidSessionTarget;
        return .{ .commit = .{ .sha = sha, .title = record.title } };
    }
    return error.InvalidSessionTarget;
}

fn targetRecordFieldKnown(key: []const u8) bool {
    return std.mem.eql(u8, key, "type") or
        std.mem.eql(u8, key, "branch") or
        std.mem.eql(u8, key, "sha") or
        std.mem.eql(u8, key, "title");
}

fn nullableTargetRecordString(
    object: std.json.ObjectMap,
    key: []const u8,
) !?[]const u8 {
    const value = object.get(key) orelse return error.InvalidSessionTarget;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidSessionTarget,
    };
}

pub fn recordJsonFromValueAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]u8 {
    const object = switch (value) {
        .object => |item| item,
        else => return error.InvalidSessionTarget,
    };
    var field_count: usize = 0;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!targetRecordFieldKnown(entry.key_ptr.*)) {
            return error.InvalidSessionTarget;
        }
        field_count += 1;
    }
    if (field_count != 4) return error.InvalidSessionTarget;
    const record = TargetRecord{
        .type = core_json.stringField(object, "type") orelse
            return error.InvalidSessionTarget,
        .branch = try nullableTargetRecordString(object, "branch"),
        .sha = try nullableTargetRecordString(object, "sha"),
        .title = try nullableTargetRecordString(object, "title"),
    };
    _ = try fromRecord(record);
    return std.json.Stringify.valueAlloc(allocator, record, .{});
}

pub fn recordJsonFromRootAlloc(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) !?[]u8 {
    const value = root.get("target") orelse return null;
    return try recordJsonFromValueAlloc(allocator, value);
}

/// review/start omits fields that do not belong to the selected variant.
pub fn requestJsonAlloc(allocator: std.mem.Allocator, target: ReviewTarget) ![]u8 {
    return switch (target) {
        .uncommitted => std.json.Stringify.valueAlloc(
            allocator,
            .{ .type = "uncommittedChanges" },
            .{},
        ),
        .base_branch => |branch| std.json.Stringify.valueAlloc(
            allocator,
            .{ .type = "baseBranch", .branch = branch },
            .{},
        ),
        .commit => |commit| std.json.Stringify.valueAlloc(
            allocator,
            .{ .type = "commit", .sha = commit.sha, .title = commit.title },
            .{},
        ),
    };
}

/// Durable schema-4 records and identity inputs retain all four fields,
/// in their historical order, including null values for absent payloads.
pub fn toRecord(target: ReviewTarget) TargetRecord {
    return switch (target) {
        .uncommitted => .{ .type = "uncommittedChanges" },
        .base_branch => |branch| .{ .type = "baseBranch", .branch = branch },
        .commit => |commit| .{ .type = "commit", .sha = commit.sha, .title = commit.title },
    };
}

pub fn startParamsJsonAlloc(
    allocator: std.mem.Allocator,
    parent_thread_id: []const u8,
    target: ReviewTarget,
) ![]u8 {
    const target_json = try requestJsonAlloc(allocator, target);
    defer allocator.free(target_json);
    const parent_thread_id_json = try std.json.Stringify.valueAlloc(
        allocator,
        parent_thread_id,
        .{},
    );
    defer allocator.free(parent_thread_id_json);
    return allocator.print(
        "{{\"threadId\":{s},\"delivery\":\"inline\",\"target\":{s}}}",
        .{ parent_thread_id_json, target_json },
    );
}

test "review target variants retain exact request and historical record bytes" {
    const Case = struct {
        target: ReviewTarget,
        request: []const u8,
        record: []const u8,
    };
    const cases = [_]Case{
        .{
            .target = .uncommitted,
            .request = "{\"type\":\"uncommittedChanges\"}",
            .record = "{\"type\":\"uncommittedChanges\",\"branch\":null,\"" ++
                "sha\":null,\"title\":null}",
        },
        .{
            .target = .{ .base_branch = "feature/\"quoted\"" },
            .request = "{\"type\":\"baseBranch\",\"branch\":\"feature/\\\"quoted\\\"\"}",
            .record = "{\"type\":\"baseBranch\",\"branch\":\"feature/\\\"" ++
                "quoted\\\"\",\"sha\":null,\"title\":null}",
        },
        .{
            .target = .{ .commit = .{ .sha = "abcdef" } },
            .request = "{\"type\":\"commit\",\"sha\":\"abcdef\",\"title\":null}",
            .record = "{\"type\":\"commit\",\"branch\":null,\"sha\":\"abcdef\",\"title\":null}",
        },
        .{
            .target = .{ .commit = .{ .sha = "abcdef", .title = "exact\ntitle" } },
            .request = "{\"type\":\"commit\",\"sha\":\"abcdef\",\"title\":\"exact\\ntitle\"}",
            .record = "{\"type\":\"commit\",\"branch\":null,\"sha\":\"abc" ++
                "def\",\"title\":\"exact\\ntitle\"}",
        },
    };
    const allocator = std.testing.allocator;
    for (cases) |case| {
        const actual_request = try requestJsonAlloc(allocator, case.target);
        defer allocator.free(actual_request);
        try std.testing.expectEqualStrings(case.request, actual_request);
        const actual_record = try std.json.Stringify.valueAlloc(
            allocator,
            toRecord(case.target),
            .{},
        );
        defer allocator.free(actual_record);
        try std.testing.expectEqualStrings(case.record, actual_record);
        const restored = try fromRecord(toRecord(case.target));
        const restored_request = try requestJsonAlloc(allocator, restored);
        defer allocator.free(restored_request);
        try std.testing.expectEqualStrings(case.request, restored_request);
        const start_params = try startParamsJsonAlloc(allocator, "thread\"id", case.target);
        defer allocator.free(start_params);
        const expected_params = try allocator.print(
            "{{\"threadId\":\"thread\\\"id\",\"delivery\":\"inline\",\"target\":{s}}}",
            .{case.request},
        );
        defer allocator.free(expected_params);
        try std.testing.expectEqualStrings(expected_params, start_params);
    }
}

test "historical target admission rejects invalid payload combinations" {
    const invalid = [_]TargetRecord{
        .{ .type = "unknown" },
        .{ .type = "uncommittedChanges", .branch = "main" },
        .{ .type = "uncommittedChanges", .sha = "abc" },
        .{ .type = "uncommittedChanges", .title = "title" },
        .{ .type = "baseBranch" },
        .{ .type = "baseBranch", .branch = "" },
        .{ .type = "baseBranch", .branch = "main", .sha = "abc" },
        .{ .type = "baseBranch", .branch = "main", .title = "title" },
        .{ .type = "commit" },
        .{ .type = "commit", .sha = "" },
        .{ .type = "commit", .sha = "abc", .branch = "main" },
    };
    for (invalid) |record| try std.testing.expectError(
        error.InvalidSessionTarget,
        fromRecord(record),
    );
    // Historical admission preserves stored spelling. Only fresh execution
    // performs whitespace normalization and Git resolution.
    const branch = try fromRecord(.{ .type = "baseBranch", .branch = " main " });
    try std.testing.expectEqualStrings(" main ", branch.base_branch);
    const commit = try fromRecord(.{ .type = "commit", .sha = " abc ", .title = "" });
    try std.testing.expectEqualStrings(" abc ", commit.commit.sha);
    try std.testing.expectEqualStrings("", commit.commit.title.?);
}

test "historical target JSON retains strict field admission" {
    const invalid = [_][]const u8{
        "null",
        "{\"type\":\"uncommittedChanges\",\"branch\":null,\"sha\":null}",
        "{\"type\":\"uncommittedChanges\",\"branch\":null,\"" ++
            "sha\":null,\"title\":null,\"extra\":null}",
        "{\"type\":\"baseBranch\",\"branch\":false,\"sha\":null,\"title\":null}",
        "{\"type\":\"commit\",\"branch\":null,\"sha\":123,\"title\":null}",
    };
    for (invalid) |raw| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
        defer parsed.deinit();
        try std.testing.expectError(
            error.InvalidSessionTarget,
            recordJsonFromValueAlloc(std.testing.allocator, parsed.value),
        );
    }
}

fn checkTargetSerializationAllocation(allocator: std.mem.Allocator) !void {
    const raw = "{\"title\":\"title\",\"sha\":\"abc\",\"branch\":null,\"type\":\"commit\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const record_json = try recordJsonFromValueAlloc(allocator, parsed.value);
    defer allocator.free(record_json);
    try std.testing.expectEqualStrings(
        "{\"type\":\"commit\",\"branch\":null,\"sha\":\"abc\",\"title\":\"title\"}",
        record_json,
    );
    const params = try startParamsJsonAlloc(allocator, "thread", .{ .commit = .{
        .sha = "abc",
        .title = "title",
    } });
    defer allocator.free(params);
    try std.testing.expectEqualStrings(
        "{\"threadId\":\"thread\",\"delivery\":\"inline\",\"" ++
            "target\":{\"type\":\"commit\",\"sha\":\"abc\",\"title\":\"title\"}}",
        params,
    );
}

test "target serialization releases partial allocations and propagates exhaustion" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkTargetSerializationAllocation,
        .{},
    );
}
