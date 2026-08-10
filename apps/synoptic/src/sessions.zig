const std = @import("std");
const cas_runtime = @import("cas_runtime");

pub const Registry = struct {
    allocator: std.mem.Allocator,
    actor: ?cas_runtime.Actor = null,
    primary_thread_id: ?[]u8 = null,
    latest_primary_turn_id: ?[]u8 = null,

    pub fn start(allocator: std.mem.Allocator, cwd: []const u8, codex_path: []const u8) !Registry {
        var registry = Registry{ .allocator = allocator };
        registry.actor = try cas_runtime.Client.startActor(allocator, .{
            .cwd = cwd, .codex_path = codex_path, .read_only = true,
            .file_approval = "decline", .client_name = "synoptic", .client_title = "Synoptic", .client_version = "0.1.0",
        }, .{});
        return registry;
    }

    pub fn deinit(self: *Registry) void {
        if (self.actor) |*actor| actor.deinit();
        if (self.primary_thread_id) |v| self.allocator.free(v);
        if (self.latest_primary_turn_id) |v| self.allocator.free(v);
    }

    pub fn createPrimary(self: *Registry, cwd: []const u8) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        const params = try std.fmt.allocPrint(self.allocator, "{{\"cwd\":{f},\"ephemeral\":true}}", .{std.json.fmt(cwd, .{})}); defer self.allocator.free(params);
        const response = try actor.requestJson("thread/start", params, null); defer self.allocator.free(response);
        self.primary_thread_id = try extractString(self.allocator, response, &.{ "result", "thread", "id" });
        const turn_params = try std.fmt.allocPrint(self.allocator,
            "{{\"threadId\":{f},\"input\":[{{\"type\":\"text\",\"text\":\"Build common PR context. Do not take GitHub actions.\"}}]}}",
            .{std.json.fmt(self.primary_thread_id.?, .{})});
        defer self.allocator.free(turn_params);
        const turn = try actor.requestJson("turn/start", turn_params, null); defer self.allocator.free(turn);
        self.latest_primary_turn_id = extractString(self.allocator, turn, &.{ "result", "turn", "id" }) catch try self.allocator.dupe(u8, "initial-primary-turn");
    }

    fn extractString(allocator: std.mem.Allocator, raw: []const u8, path: []const []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{}); defer parsed.deinit();
        var value = parsed.value;
        for (path) |name| value = switch (value) { .object => |o| o.get(name) orelse return error.MissingAppServerField, else => return error.MissingAppServerField };
        return switch (value) { .string => |s| allocator.dupe(u8, s), else => error.MissingAppServerField };
    }
};

test "file selection remains gated without completed primary" {
    const registry = Registry{ .allocator = std.testing.allocator };
    try std.testing.expect(registry.latest_primary_turn_id == null);
}
