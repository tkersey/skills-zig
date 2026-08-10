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

pub const FileReviewStartMode = enum { immediate, idle };

const ExclusionRule = struct {
    reason: []u8,
    globs: std.ArrayList([]u8) = .empty,

    fn deinit(self: *ExclusionRule, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        for (self.globs.items) |glob| allocator.free(glob);
        self.globs.deinit(allocator);
    }
};

pub const Settings = struct {
    allocator: std.mem.Allocator,
    file_review_start_mode: FileReviewStartMode = .immediate,
    browser_open: bool = true,
    worktree_prefer_current_pr_checkout: bool = true,
    exclusions_enabled: bool = true,
    additional_globs: std.ArrayList([]u8) = .empty,
    removed_default_globs: std.ArrayList([]u8) = .empty,
    exclusion_rules: std.ArrayList(ExclusionRule) = .empty,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, skill_root: []const u8) !Settings {
        var settings = Settings{ .allocator = allocator };
        errdefer settings.deinit();
        try settings.loadSkillExclusions(io, skill_root);
        if (try configPathAlloc(allocator, environment)) |path| {
            defer allocator.free(path);
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
                error.FileNotFound => return settings,
                else => return err,
            };
            defer allocator.free(bytes);
            try settings.applyToml(bytes);
        }
        return settings;
    }

    pub fn deinit(self: *Settings) void {
        for (self.additional_globs.items) |glob| self.allocator.free(glob);
        self.additional_globs.deinit(self.allocator);
        for (self.removed_default_globs.items) |glob| self.allocator.free(glob);
        self.removed_default_globs.deinit(self.allocator);
        for (self.exclusion_rules.items) |*rule| rule.deinit(self.allocator);
        self.exclusion_rules.deinit(self.allocator);
    }

    pub fn classify(self: *const Settings, path: []const u8, diff: []const u8) ?[]const u8 {
        if (!self.exclusions_enabled) return null;
        return self.classifyPath(path) orelse self.classifyDiff(diff);
    }

    pub fn classifyPath(self: *const Settings, path: []const u8) ?[]const u8 {
        if (!self.exclusions_enabled) return null;
        for (self.additional_globs.items) |glob| if (globMatches(glob, path)) return "configured-glob";
        for (self.exclusion_rules.items) |rule| for (rule.globs.items) |glob| {
            if (containsExact(self.removed_default_globs.items, glob)) continue;
            if (globMatches(glob, path)) return rule.reason;
        };
        return null;
    }

    pub fn classifyDiff(self: *const Settings, diff: []const u8) ?[]const u8 {
        if (!self.exclusions_enabled) return null;
        if (std.mem.indexOf(u8, diff, "GIT binary patch") != null or std.mem.indexOf(u8, diff, "Binary files ") != null) return "binary";
        return null;
    }

    fn loadSkillExclusions(self: *Settings, io: std.Io, skill_root: []const u8) !void {
        const path = try std.fs.path.join(self.allocator, &.{ skill_root, "assets", "exclusions.json" });
        defer self.allocator.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(256 * 1024));
        defer self.allocator.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return error.InvalidExclusionsManifest;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidExclusionsManifest;
        const object = parsed.value.object;
        if (object.count() != 2) return error.InvalidExclusionsManifest;
        const schema = object.get("schema") orelse return error.InvalidExclusionsManifest;
        if (schema != .string or !std.mem.eql(u8, schema.string, "synoptic-exclusions/v1")) return error.InvalidExclusionsManifest;
        const rules = object.get("rules") orelse return error.InvalidExclusionsManifest;
        if (rules != .array or rules.array.items.len == 0 or rules.array.items.len > 64) return error.InvalidExclusionsManifest;
        for (rules.array.items) |value| {
            if (value != .object or value.object.count() != 2) return error.InvalidExclusionsManifest;
            const reason_value = value.object.get("reason") orelse return error.InvalidExclusionsManifest;
            const globs_value = value.object.get("globs") orelse return error.InvalidExclusionsManifest;
            if (reason_value != .string or !validExclusionReason(reason_value.string) or globs_value != .array or globs_value.array.items.len == 0 or globs_value.array.items.len > 256) return error.InvalidExclusionsManifest;
            var rule = ExclusionRule{ .reason = try self.allocator.dupe(u8, reason_value.string) };
            errdefer rule.deinit(self.allocator);
            for (globs_value.array.items) |glob_value| {
                if (glob_value != .string or !validGlob(glob_value.string)) return error.InvalidExclusionsManifest;
                try rule.globs.append(self.allocator, try self.allocator.dupe(u8, glob_value.string));
            }
            try self.exclusion_rules.append(self.allocator, rule);
        }
    }

    fn applyToml(self: *Settings, bytes: []const u8) !void {
        var section: enum { none, file_review, browser, worktree, exclusions } = .none;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            const without_comment = stripTomlComment(raw_line);
            const line = std.mem.trim(u8, without_comment, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == '[') {
                if (line.len < 3 or line[line.len - 1] != ']') return error.InvalidSynopticConfig;
                const name = line[1 .. line.len - 1];
                section = if (std.mem.eql(u8, name, "file_review")) .file_review else if (std.mem.eql(u8, name, "browser")) .browser else if (std.mem.eql(u8, name, "worktree")) .worktree else if (std.mem.eql(u8, name, "exclusions")) .exclusions else return error.InvalidSynopticConfig;
                continue;
            }
            const equal = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSynopticConfig;
            const key = std.mem.trim(u8, line[0..equal], " \t");
            const value = std.mem.trim(u8, line[equal + 1 ..], " \t");
            switch (section) {
                .file_review => if (std.mem.eql(u8, key, "start_mode")) {
                    const text = try tomlString(value);
                    self.file_review_start_mode = if (std.mem.eql(u8, text, "immediate")) .immediate else if (std.mem.eql(u8, text, "idle")) .idle else return error.InvalidSynopticConfig;
                } else return error.InvalidSynopticConfig,
                .browser => {
                    if (std.mem.eql(u8, key, "open")) self.browser_open = try tomlBool(value) else return error.InvalidSynopticConfig;
                },
                .worktree => {
                    if (std.mem.eql(u8, key, "prefer_current_pr_checkout")) self.worktree_prefer_current_pr_checkout = try tomlBool(value) else return error.InvalidSynopticConfig;
                },
                .exclusions => if (std.mem.eql(u8, key, "enabled")) {
                    self.exclusions_enabled = try tomlBool(value);
                } else if (std.mem.eql(u8, key, "additional_globs")) {
                    try replaceStringArray(self.allocator, &self.additional_globs, value);
                } else if (std.mem.eql(u8, key, "removed_default_globs")) {
                    try replaceStringArray(self.allocator, &self.removed_default_globs, value);
                } else return error.InvalidSynopticConfig,
                .none => return error.InvalidSynopticConfig,
            }
        }
    }
};

fn configPathAlloc(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) !?[]u8 {
    if (environment.get("XDG_CONFIG_HOME")) |root| return try std.fs.path.join(allocator, &.{ root, "synoptic", "config.toml" });
    if (environment.get("HOME")) |home| return try std.fs.path.join(allocator, &.{ home, ".config", "synoptic", "config.toml" });
    return null;
}

fn validExclusionReason(reason: []const u8) bool {
    return std.mem.eql(u8, reason, "generated") or std.mem.eql(u8, reason, "vendored") or std.mem.eql(u8, reason, "binary") or std.mem.eql(u8, reason, "minified") or std.mem.eql(u8, reason, "lockfile") or std.mem.eql(u8, reason, "snapshot");
}
fn validGlob(glob: []const u8) bool {
    return glob.len > 0 and glob.len <= 1024 and !std.fs.path.isAbsolute(glob) and std.mem.indexOf(u8, glob, "..") == null and std.mem.indexOfScalar(u8, glob, '\\') == null;
}
fn containsExact(values: []const []u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}
fn stripTomlComment(line: []const u8) []const u8 {
    var quoted = false;
    for (line, 0..) |byte, i| {
        if (byte == '"' and (i == 0 or line[i - 1] != '\\')) quoted = !quoted;
        if (byte == '#' and !quoted) return line[0..i];
    }
    return line;
}
fn tomlString(value: []const u8) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidSynopticConfig;
    const text = value[1 .. value.len - 1];
    if (std.mem.indexOfScalar(u8, text, '\\') != null or std.mem.indexOfScalar(u8, text, '"') != null) return error.InvalidSynopticConfig;
    return text;
}
fn tomlBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidSynopticConfig;
}
fn replaceStringArray(allocator: std.mem.Allocator, target: *std.ArrayList([]u8), value: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{}) catch return error.InvalidSynopticConfig;
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len > 256) return error.InvalidSynopticConfig;
    var next: std.ArrayList([]u8) = .empty;
    errdefer {
        for (next.items) |entry| allocator.free(entry);
        next.deinit(allocator);
    }
    for (parsed.value.array.items) |entry| {
        if (entry != .string or !validGlob(entry.string)) return error.InvalidSynopticConfig;
        try next.append(allocator, try allocator.dupe(u8, entry.string));
    }
    for (target.items) |entry| allocator.free(entry);
    target.deinit(allocator);
    target.* = next;
}

fn globMatches(pattern: []const u8, path: []const u8) bool {
    return globMatchFrom(pattern, 0, path, 0);
}
fn globMatchFrom(pattern: []const u8, pattern_index: usize, path: []const u8, path_index: usize) bool {
    var pi = pattern_index;
    var si = path_index;
    while (pi < pattern.len) {
        if (pattern[pi] == '*') {
            const double = pi + 1 < pattern.len and pattern[pi + 1] == '*';
            pi += if (double) 2 else 1;
            if (double and pi < pattern.len and pattern[pi] == '/') pi += 1;
            var end = si;
            while (true) {
                if (globMatchFrom(pattern, pi, path, end)) return true;
                if (end == path.len or (!double and path[end] == '/')) break;
                end += 1;
            }
            return false;
        }
        if (si == path.len or (pattern[pi] != '?' and pattern[pi] != path[si])) return false;
        if (pattern[pi] == '?' and path[si] == '/') return false;
        pi += 1;
        si += 1;
    }
    return si == path.len;
}

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
    const methods = [_][]const u8{ "initialize", "initialized", "thread/start", "thread/fork", "turn/start", "turn/steer", "turn/interrupt", "thread/inject_items", "item/tool/call", "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval" };
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
    const approval_schemas = [_]struct { file: []const u8, properties: []const []const u8, required: []const []const u8, values: []const []const u8 }{
        .{ .file = "CommandExecutionRequestApprovalParams.json", .properties = &.{ "threadId", "availableDecisions" }, .required = &.{"threadId"}, .values = &.{} },
        .{ .file = "CommandExecutionRequestApprovalResponse.json", .properties = &.{"decision"}, .required = &.{"decision"}, .values = &.{ "accept", "acceptForSession", "decline", "cancel" } },
        .{ .file = "FileChangeRequestApprovalResponse.json", .properties = &.{"decision"}, .required = &.{"decision"}, .values = &.{"decline"} },
        .{ .file = "PermissionsRequestApprovalParams.json", .properties = &.{ "threadId", "permissions" }, .required = &.{ "threadId", "permissions" }, .values = &.{} },
        .{ .file = "PermissionsRequestApprovalResponse.json", .properties = &.{ "permissions", "scope" }, .required = &.{"permissions"}, .values = &.{ "turn", "session" } },
    };
    for (approval_schemas) |approval| {
        const bytes = readSchema(allocator, io, out_dir, approval.file) catch return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: missing approval schema {s}", .{ version, approval.file }));
        defer allocator.free(bytes);
        var schema_json = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: invalid approval schema {s}", .{ version, approval.file }));
        defer schema_json.deinit();
        if (!approvalSchemaHas(schema_json.value, approval.properties, approval.required, approval.values)) return @as(?[]u8, try std.fmt.allocPrint(allocator, "installed Codex {s}: incompatible approval schema {s}", .{ version, approval.file }));
    }
    return null;
}

fn approvalSchemaHas(value: std.json.Value, properties: []const []const u8, required: []const []const u8, values: []const []const u8) bool {
    if (value != .object) return false;
    const property_map = value.object.get("properties") orelse return false;
    if (property_map != .object) return false;
    for (properties) |name| if (!property_map.object.contains(name)) return false;
    const required_values = value.object.get("required") orelse return false;
    if (required_values != .array) return false;
    for (required) |name| {
        var found = false;
        for (required_values.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, name)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    for (values) |expected| if (!containsExactString(value, expected)) return false;
    return true;
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

test "command approvals installed schema requires exact request and response surfaces" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const script_path = try std.fs.path.join(allocator, &.{ root, "codex" });
    defer allocator.free(script_path);
    const script =
        \\#!/bin/sh
        \\set -eu
        \\if [ "${1:-}" = --version ]; then echo 'codex-test approvals'; exit 0; fi
        \\out=''
        \\while [ $# -gt 0 ]; do if [ "$1" = --out ]; then shift; out="$1"; fi; shift; done
        \\mkdir -p "$out/v2"
        \\printf '%s' '{"methods":["initialize","initialized","thread/start","thread/fork","turn/start","turn/steer","turn/interrupt","thread/inject_items","item/tool/call","item/commandExecution/requestApproval","item/fileChange/requestApproval","item/permissions/requestApproval"]}' > "$out/codex_app_server_protocol.schemas.json"
        \\cp "$out/codex_app_server_protocol.schemas.json" "$out/codex_app_server_protocol.v2.schemas.json"
        \\printf '%s' '{"lastTurnId":{},"ephemeral":{}}' > "$out/v2/ThreadForkParams.json"
        \\printf '%s' '{"dynamicTools":{}}' > "$out/v2/ThreadStartParams.json"
        \\printf '%s' '{"SkillUserInput":{"required":["name","path","type"]}}' > "$out/v2/TurnStartParams.json"
        \\for f in ThreadStartedNotification TurnStartedNotification ItemStartedNotification AgentMessageDeltaNotification; do printf '%s' '{}' > "$out/v2/$f.json"; done
        \\printf '%s' '{"properties":{"threadId":{},"availableDecisions":{}},"required":["threadId"]}' > "$out/CommandExecutionRequestApprovalParams.json"
        \\printf '%s' '{"properties":{"decision":{}},"required":["decision"],"values":["accept","acceptForSession","decline","cancel"]}' > "$out/CommandExecutionRequestApprovalResponse.json"
        \\printf '%s' '{"properties":{"decision":{}},"required":["decision"],"values":["decline"]}' > "$out/FileChangeRequestApprovalResponse.json"
        \\printf '%s' '{"properties":{"threadId":{},"permissions":{}},"required":["threadId","permissions"]}' > "$out/PermissionsRequestApprovalParams.json"
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "codex", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(io, script_path, std.Io.File.Permissions.fromMode(0o755), .{});
    const schema = try std.fs.path.join(allocator, &.{ root, "schema" });
    defer allocator.free(schema);
    const problem = (try codexSchemaProblemAlloc(allocator, io, script_path, schema)).?;
    defer allocator.free(problem);
    try std.testing.expect(std.mem.indexOf(u8, problem, "codex-test approvals") != null);
    try std.testing.expect(std.mem.indexOf(u8, problem, "PermissionsRequestApprovalResponse.json") != null);
}
