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
/// Keeps the browser event stream live without requiring a client command.
pub const visible_event_flush_ms: u32 = 50;
pub const lifecycle_schema = "synoptic-runtime/v1";
pub const lifecycle_ready_timeout_ms: u32 = 30_000;
pub const lifecycle_stop_timeout_ms: u32 = 5_000;

pub fn codexSchemaProblemAlloc(allocator: std.mem.Allocator, io: std.Io, codex_path: []const u8, out_dir: []const u8) !?[]u8 {
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    const generated = try std.process.run(allocator, io, .{ .argv = &.{ codex_path, "app-server", "generate-json-schema", "--experimental", "--out", out_dir } });
    defer allocator.free(generated.stdout);
    defer allocator.free(generated.stderr);
    const version_result = try std.process.run(allocator, io, .{ .argv = &.{ codex_path, "--version" } });
    defer allocator.free(version_result.stdout);
    defer allocator.free(version_result.stderr);
    const version = std.mem.trim(u8, version_result.stdout, "\r\n");
    if (generated.term != .exited or generated.term.exited != 0) return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: schema generation failed", .{version}));
    const aggregate = readSchema(allocator, io, out_dir, "codex_app_server_protocol.schemas.json") catch return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: missing schema bundle codex_app_server_protocol.schemas.json", .{version}));
    defer allocator.free(aggregate);
    const v2 = readSchema(allocator, io, out_dir, "codex_app_server_protocol.v2.schemas.json") catch return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: missing schema bundle codex_app_server_protocol.v2.schemas.json", .{version}));
    defer allocator.free(v2);
    var aggregate_json = std.json.parseFromSlice(std.json.Value, allocator, aggregate, .{}) catch return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: invalid app-server schema bundle", .{version}));
    defer aggregate_json.deinit();
    var v2_json = std.json.parseFromSlice(std.json.Value, allocator, v2, .{}) catch return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: invalid app-server v2 schema bundle", .{version}));
    defer v2_json.deinit();
    const methods = [_][]const u8{ "initialize", "initialized", "thread/start", "thread/fork", "turn/start", "turn/steer", "turn/interrupt", "thread/inject_items", "item/tool/call" };
    for (methods) |method| if (!containsExactString(aggregate_json.value, method) and !containsExactString(v2_json.value, method)) return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: missing app-server surface {s}", .{ version, method }));
    const fork = readSchema(allocator, io, out_dir, "v2/ThreadForkParams.json") catch return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: missing thread/fork schema", .{version}));
    defer allocator.free(fork);
    for ([_][]const u8{ "lastTurnId", "ephemeral" }) |field| if (std.mem.indexOf(u8, fork, field) == null) return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: thread/fork missing {s}", .{ version, field }));
    const start = readSchema(allocator, io, out_dir, "v2/ThreadStartParams.json") catch return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: missing thread/start schema", .{version}));
    defer allocator.free(start);
    if (std.mem.indexOf(u8, start, "dynamicTools") == null) return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: thread/start missing dynamicTools", .{version}));
    const turn = readSchema(allocator, io, out_dir, "v2/TurnStartParams.json") catch return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: missing turn/start schema", .{version}));
    defer allocator.free(turn);
    var turn_schema = std.json.parseFromSlice(std.json.Value, allocator, turn, .{}) catch return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: invalid TurnStartParams schema", .{version}));
    defer turn_schema.deinit();
    if (!hasCompleteSkillInput(turn_schema.value, false)) return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: SkillUserInput must require name, path, and type", .{version}));
    const notification_files = [_][]const u8{ "v2/ThreadStartedNotification.json", "v2/TurnStartedNotification.json", "v2/ItemStartedNotification.json", "v2/AgentMessageDeltaNotification.json" };
    for (notification_files) |file| {
        const bytes = readSchema(allocator, io, out_dir, file) catch return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: missing notification family {s}", .{ version, file }));
        allocator.free(bytes);
    }
    return null;
}

fn containsExactString(value: std.json.Value, needle: []const u8) bool {
    return switch (value) {
        .string => |text| std.mem.eql(u8, text, needle),
        .array => |array| found: {
            for (array.items) |item| if (containsExactString(item, needle)) break :found true;
            break :found false;
        },
        .object => |object| found: {
            var iterator = object.iterator();
            while (iterator.next()) |entry| if (containsExactString(entry.value_ptr.*, needle)) break :found true;
            break :found false;
        },
        else => false,
    };
}

fn hasCompleteSkillInput(value: std.json.Value, named_skill: bool) bool {
    return switch (value) {
        .object => |object| found: {
            var is_skill = named_skill;
            if (object.get("title")) |title| if (title == .string and std.mem.eql(u8, title.string, "SkillUserInput")) {
                is_skill = true;
            };
            if (is_skill) if (object.get("required")) |required| if (required == .array) {
                var name = false;
                var path = false;
                var kind = false;
                for (required.array.items) |item| if (item == .string) {
                    name = name or std.mem.eql(u8, item.string, "name");
                    path = path or std.mem.eql(u8, item.string, "path");
                    kind = kind or std.mem.eql(u8, item.string, "type");
                };
                if (name and path and kind) break :found true;
            };
            var iterator = object.iterator();
            while (iterator.next()) |entry| if (hasCompleteSkillInput(entry.value_ptr.*, std.mem.eql(u8, entry.key_ptr.*, "SkillUserInput"))) break :found true;
            break :found false;
        },
        .array => |array| found: {
            for (array.items) |item| if (hasCompleteSkillInput(item, false)) break :found true;
            break :found false;
        },
        else => false,
    };
}

fn readSchema(allocator: std.mem.Allocator, io: std.Io, root: []const u8, relative: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ root, relative });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
}

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

test "session context installed schema drift names Codex version and missing surface" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const script_path = try std.fs.path.join(allocator, &.{ root, "codex" });
    defer allocator.free(script_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "codex", .data = "#!/bin/sh\nset -eu\nif [ \"${1:-}\" = --version ]; then echo 'codex-test 9'; exit 0; fi\nout=''\nwhile [ $# -gt 0 ]; do if [ \"$1\" = --out ]; then shift; out=\"$1\"; fi; shift; done\nmkdir -p \"$out/v2\"\necho '{\"methods\":[\"initialize\"]}' > \"$out/codex_app_server_protocol.schemas.json\"\ncp \"$out/codex_app_server_protocol.schemas.json\" \"$out/codex_app_server_protocol.v2.schemas.json\"\n" });
    try std.Io.Dir.cwd().setFilePermissions(io, script_path, std.Io.File.Permissions.fromMode(0o755), .{});
    const schema = try std.fs.path.join(allocator, &.{ root, "schema" });
    defer allocator.free(schema);
    const problem = (try codexSchemaProblemAlloc(allocator, io, script_path, schema)).?;
    defer allocator.free(problem);
    try std.testing.expect(std.mem.indexOf(u8, problem, "codex-test 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, problem, "initialized") != null);
}
