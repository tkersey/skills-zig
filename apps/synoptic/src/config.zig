const std = @import("std");

pub const skill_abi = "synoptic-skill-abi/v1";
pub const ui_abi = "synoptic-ui/v1";
pub const manifest_schema = "synoptic-ui-manifest/v1";

pub const LaunchOptions = struct {
    cwd: []const u8,
    skill_root: []const u8,
    pr: ?[]const u8 = null,
    json: bool = false,
    no_browser: bool = false,
};

pub const max_page_count: usize = 10_000;
pub const max_open_sessions: usize = 256;
pub const max_visible_events: usize = 1024;

pub fn validateManifest(allocator: std.mem.Allocator, io: std.Io, skill_root: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ skill_root, "assets", "ui", "manifest.json" });
    defer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidUiManifest,
    };
    try expectString(obj, "schema", manifest_schema);
    try expectString(obj, "uiAbi", ui_abi);
    try expectString(obj, "requiredSkillAbi", skill_abi);
    try expectString(obj, "entry", "index.html");
}

fn expectString(obj: std.json.ObjectMap, name: []const u8, expected: []const u8) !void {
    const value = obj.get(name) orelse return error.InvalidUiManifest;
    if (value != .string or !std.mem.eql(u8, value.string, expected)) return error.InvalidUiManifest;
}

test "manifest contract rejects ABI drift" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"schema\":\"synoptic-ui-manifest/v1\"}", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidUiManifest, expectString(parsed.value.object, "uiAbi", ui_abi));
}
