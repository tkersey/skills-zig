const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;

pub const ProofScope = enum { focused, affected_aggregate, full_closure, unknown };
pub const ClassificationSource = enum { explicit, inferred };

pub const ProofRow = struct {
    command: []u8,
    scope: ProofScope,
    classification_source: ClassificationSource,
    current: bool,

    pub fn deinit(self: *ProofRow, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
    }
};

pub fn classifyCommand(command: []const u8, explicit_label: ?[]const u8) struct { ProofScope, ClassificationSource } {
    if (explicit_label) |label| {
        if (scopeFromText(label)) |scope| return .{ scope, .explicit };
    }
    if (scopeFromText(command)) |scope| return .{ scope, .inferred };
    return .{ .unknown, .inferred };
}

pub fn collectProofs(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace) ![]ProofRow {
    var rows: std.ArrayList(ProofRow) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    var mutation_after_last_proof = false;
    var idx = trace.tools.items.len;
    while (idx > 0) {
        idx -= 1;
        const tool = trace.tools.items[idx];
        if (isMaterialMutation(tool)) {
            mutation_after_last_proof = true;
            continue;
        }
        const command = tool.command_text orelse continue;
        if (!isProofCommand(command)) continue;
        const classified = classifyCommand(command, null);
        try rows.append(allocator, .{
            .command = try allocator.dupe(u8, command),
            .scope = classified[0],
            .classification_source = classified[1],
            .current = !mutation_after_last_proof and proofSucceeded(tool),
        });
    }
    std.mem.reverse(ProofRow, rows.items);
    return rows.toOwnedSlice(allocator);
}

fn scopeFromText(text: []const u8) ?ProofScope {
    if (contains(text, "focused")) return .focused;
    if (contains(text, "affected_aggregate") or contains(text, "affected aggregate")) return .affected_aggregate;
    if (contains(text, "full_closure") or contains(text, "full closure")) return .full_closure;
    if (contains(text, "zig build test --summary all")) return .full_closure;
    if (contains(text, "zig build test-seq")) return .focused;
    if (contains(text, "command_surface_gate") or contains(text, "build-seq")) return .affected_aggregate;
    return null;
}

fn isProofCommand(command: []const u8) bool {
    return contains(command, "zig build") or contains(command, "command_surface_gate") or contains(command, "test ");
}

fn proofSucceeded(tool: canonical_trace.ToolLifecycleRecord) bool {
    if (tool.exit_code) |code| return code == 0;
    return false;
}

fn isMaterialMutation(tool: canonical_trace.ToolLifecycleRecord) bool {
    if (tool.patch_success == false) return false;
    return tool.kind == .patch_apply or tool.patch_changes_json != null or toolContains(tool, "apply_patch");
}

fn toolContains(tool: canonical_trace.ToolLifecycleRecord, needle: []const u8) bool {
    if (tool.tool_name) |text| if (contains(text, needle)) return true;
    if (tool.command_text) |text| if (contains(text, needle)) return true;
    if (tool.input_text) |text| if (contains(text, needle)) return true;
    return false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "proof classifier separates explicit and inferred scopes" {
    const explicit = classifyCommand("zig build test-seq --summary all", "full_closure");
    try std.testing.expectEqual(ProofScope.full_closure, explicit[0]);
    try std.testing.expectEqual(ClassificationSource.explicit, explicit[1]);
    const inferred = classifyCommand("zig build test-seq --summary all", null);
    try std.testing.expectEqual(ProofScope.focused, inferred[0]);
    try std.testing.expectEqual(ClassificationSource.inferred, inferred[1]);
}

test "proof currentness is stale after later mutation" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/run.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.tools.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "/tmp/run.jsonl"), .kind = .exec_command, .command_text = try std.testing.allocator.dupe(u8, "zig build test --summary all") });
    try trace.tools.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "/tmp/run.jsonl"), .kind = .patch_apply, .tool_name = try std.testing.allocator.dupe(u8, "apply_patch") });
    const rows = try collectProofs(std.testing.allocator, trace);
    defer {
        for (rows) |*row| row.deinit(std.testing.allocator);
        std.testing.allocator.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(!rows[0].current);
}

test "proof currentness requires successful proof command" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/run.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.tools.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/run.jsonl"),
        .kind = .exec_command,
        .command_text = try std.testing.allocator.dupe(u8, "zig build test --summary all"),
        .exit_code = 1,
    });
    const rows = try collectProofs(std.testing.allocator, trace);
    defer {
        for (rows) |*row| row.deinit(std.testing.allocator);
        std.testing.allocator.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(!rows[0].current);
}
