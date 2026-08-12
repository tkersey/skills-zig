const std = @import("std");
const domain = @import("domain.zig");

pub const skill_abi = "synoptic-skill-abi/v1";
pub const ui_abi = "synoptic-ui/v1";
const ApprovalSchema = struct {
    file: []const u8,
    properties: []const []const u8,
    required: []const []const u8,
    value_property: ?[]const u8 = null,
    values: []const []const u8,
};
const approval_schemas = [_]ApprovalSchema{
    .{
        .file = "CommandExecutionRequestApprovalParams.json",
        .properties = &.{ "threadId", "availableDecisions" },
        .required = &.{"threadId"},
        .values = &.{},
    },
    .{
        .file = "CommandExecutionRequestApprovalResponse.json",
        .properties = &.{"decision"},
        .required = &.{"decision"},
        .value_property = "decision",
        .values = &.{ "accept", "acceptForSession", "decline", "cancel" },
    },
    .{
        .file = "FileChangeRequestApprovalResponse.json",
        .properties = &.{"decision"},
        .required = &.{"decision"},
        .value_property = "decision",
        .values = &.{"decline"},
    },
    .{
        .file = "PermissionsRequestApprovalParams.json",
        .properties = &.{ "threadId", "permissions" },
        .required = &.{ "threadId", "permissions" },
        .values = &.{},
    },
    .{
        .file = "PermissionsRequestApprovalResponse.json",
        .properties = &.{ "permissions", "scope" },
        .required = &.{"permissions"},
        .value_property = "scope",
        .values = &.{ "turn", "session" },
    },
};
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
pub const lifecycle_ready_timeout_ms: u32 = 300_000;
pub const lifecycle_stop_timeout_ms: u32 = 45_000;

pub const FileReviewStartMode = enum { immediate, idle };
const Section = enum { none, file_review, browser, worktree, exclusions };

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

    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        environment: *const std.process.Environ.Map,
        skill_root: []const u8,
    ) !Settings {
        var settings = Settings{ .allocator = allocator };
        errdefer settings.deinit();
        try settings.loadSkillExclusions(io, skill_root);
        if (try configPathAlloc(allocator, environment)) |path| {
            defer allocator.free(path);
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 *
                1024)) catch |err| switch (err) {
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
        for (self.additional_globs.items) |glob| {
            if (globMatches(self.allocator, glob, path)) return "configured-glob";
        }
        for (self.exclusion_rules.items) |rule| for (rule.globs.items) |glob| {
            if (containsExact(self.removed_default_globs.items, glob)) continue;
            if (globMatches(self.allocator, glob, path)) return rule.reason;
        };
        return null;
    }

    pub fn classifyDiff(self: *const Settings, diff: []const u8) ?[]const u8 {
        if (!self.exclusions_enabled) return null;
        return if (domain.diffDisplayState(diff) == .binary) "binary" else null;
    }

    fn loadSkillExclusions(self: *Settings, io: std.Io, skill_root: []const u8) !void {
        const path = try std.fs.path.join(
            self.allocator,
            &.{ skill_root, "assets", "exclusions.json" },
        );
        defer self.allocator.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            self.allocator,
            .limited(256 * 1024),
        );
        defer self.allocator.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch
            return error.InvalidExclusionsManifest;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidExclusionsManifest;
        const object = parsed.value.object;
        if (object.count() != 2) return error.InvalidExclusionsManifest;
        const schema = object.get("schema") orelse return error.InvalidExclusionsManifest;
        if (schema != .string or !std.mem.eql(u8, schema.string, "synoptic-exclusions/v1"))
            return error.InvalidExclusionsManifest;
        const rules = object.get("rules") orelse return error.InvalidExclusionsManifest;
        const invalid_rules = rules != .array or rules.array.items.len == 0 or
            rules.array.items.len > 64;
        if (invalid_rules) return error.InvalidExclusionsManifest;
        for (rules.array.items) |value| {
            if (value != .object or value.object.count() != 2) {
                return error.InvalidExclusionsManifest;
            }
            const reason_value = value.object.get("reason") orelse
                return error.InvalidExclusionsManifest;
            const globs_value = value.object.get("globs") orelse
                return error.InvalidExclusionsManifest;
            if (reason_value != .string or !validExclusionReason(reason_value.string) or
                globs_value != .array or globs_value.array.items.len == 0 or
                globs_value.array.items.len > 256) return error.InvalidExclusionsManifest;
            var rule = ExclusionRule{ .reason = try self.allocator.dupe(u8, reason_value.string) };
            errdefer rule.deinit(self.allocator);
            for (globs_value.array.items) |glob_value| {
                if (glob_value != .string or !validGlob(glob_value.string)) {
                    return error.InvalidExclusionsManifest;
                }
                try rule.globs.append(
                    self.allocator,
                    try self.allocator.dupe(u8, glob_value.string),
                );
            }
            try self.exclusion_rules.append(self.allocator, rule);
        }
    }

    fn applyToml(self: *Settings, bytes: []const u8) !void {
        var section: Section = .none;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            const without_comment = stripTomlComment(raw_line);
            const line = std.mem.trim(u8, without_comment, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == '[') {
                if (line.len < 3 or line[line.len - 1] != ']') return error.InvalidSynopticConfig;
                const name = line[1 .. line.len - 1];
                section = try parseSection(name);
                continue;
            }
            const equal = std.mem.indexOfScalar(u8, line, '=') orelse
                return error.InvalidSynopticConfig;
            const key = std.mem.trim(u8, line[0..equal], " \t");
            const value = std.mem.trim(u8, line[equal + 1 ..], " \t");
            switch (section) {
                .file_review => if (std.mem.eql(u8, key, "start_mode")) {
                    const text = try tomlString(value);
                    self.file_review_start_mode = if (std.mem.eql(u8, text, "immediate"))
                        .immediate
                    else if (std.mem.eql(u8, text, "idle"))
                        .idle
                    else
                        return error.InvalidSynopticConfig;
                } else return error.InvalidSynopticConfig,
                .browser => {
                    if (std.mem.eql(u8, key, "open")) {
                        self.browser_open = try tomlBool(value);
                    } else return error.InvalidSynopticConfig;
                },
                .worktree => {
                    if (std.mem.eql(u8, key, "prefer_current_pr_checkout"))
                        self.worktree_prefer_current_pr_checkout = try tomlBool(value)
                    else
                        return error.InvalidSynopticConfig;
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

fn parseSection(name: []const u8) !Section {
    if (std.mem.eql(u8, name, "file_review")) return .file_review;
    if (std.mem.eql(u8, name, "browser")) return .browser;
    if (std.mem.eql(u8, name, "worktree")) return .worktree;
    if (std.mem.eql(u8, name, "exclusions")) return .exclusions;
    return error.InvalidSynopticConfig;
}

fn configPathAlloc(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
) !?[]u8 {
    if (environment.get("XDG_CONFIG_HOME")) |root| if (std.fs.path.isAbsolute(root))
        return try std.fs.path.join(allocator, &.{ root, "synoptic", "config.toml" });
    if (environment.get("HOME")) |home| if (std.fs.path.isAbsolute(home))
        return try std.fs.path.join(
            allocator,
            &.{ home, ".config", "synoptic", "config.toml" },
        );
    return null;
}

fn validExclusionReason(reason: []const u8) bool {
    return std.mem.eql(u8, reason, "generated") or std.mem.eql(u8, reason, "vendored") or
        std.mem.eql(u8, reason, "binary") or std.mem.eql(u8, reason, "minified") or
        std.mem.eql(u8, reason, "lockfile") or std.mem.eql(u8, reason, "snapshot");
}
fn validGlob(glob: []const u8) bool {
    return glob.len > 0 and glob.len <= 1024 and !std.fs.path.isAbsolute(glob) and
        std.mem.indexOf(u8, glob, "..") == null and std.mem.indexOfScalar(u8, glob, '\\') == null;
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
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        return error.InvalidSynopticConfig;
    }
    const text = value[1 .. value.len - 1];
    if (std.mem.indexOfScalar(u8, text, '\\') != null or std.mem.indexOfScalar(u8, text, '"') !=
        null) return error.InvalidSynopticConfig;
    return text;
}
fn tomlBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidSynopticConfig;
}
fn replaceStringArray(
    allocator: std.mem.Allocator,
    target: *std.ArrayList([]u8),
    value: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        value,
        .{},
    ) catch return error.InvalidSynopticConfig;
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len > 256) {
        return error.InvalidSynopticConfig;
    }
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

const GlobState = struct { pattern: usize, path: usize };

fn appendGlobState(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(GlobState),
    visited: []bool,
    path_states: usize,
    state: GlobState,
) !void {
    const index = state.pattern * path_states + state.path;
    if (visited[index]) return;
    visited[index] = true;
    try pending.append(allocator, state);
}

fn globMatches(allocator: std.mem.Allocator, pattern: []const u8, path: []const u8) bool {
    const pattern_states = std.math.add(usize, pattern.len, 1) catch return false;
    const path_states = std.math.add(usize, path.len, 1) catch return false;
    const state_count = std.math.mul(usize, pattern_states, path_states) catch return false;
    const visited = allocator.alloc(bool, state_count) catch return false;
    defer allocator.free(visited);
    @memset(visited, false);
    var pending: std.ArrayList(GlobState) = .empty;
    defer pending.deinit(allocator);
    appendGlobState(
        allocator,
        &pending,
        visited,
        path_states,
        .{ .pattern = 0, .path = 0 },
    ) catch return false;
    while (pending.pop()) |state| {
        var pi = state.pattern;
        var si = state.path;
        while (pi < pattern.len and pattern[pi] != '*') {
            if (si == path.len) break;
            if (pattern[pi] == '?' and path[si] == '/') break;
            if (pattern[pi] != '?' and pattern[pi] != path[si]) break;
            pi += 1;
            si += 1;
        }
        if (pi == pattern.len) {
            if (si == path.len) return true;
            continue;
        }
        if (pattern[pi] != '*') continue;
        const double = pi + 1 < pattern.len and pattern[pi + 1] == '*';
        pi += if (double) 2 else 1;
        if (double and pi < pattern.len and pattern[pi] == '/') {
            pi += 1;
            appendGlobState(
                allocator,
                &pending,
                visited,
                path_states,
                .{ .pattern = pi, .path = si },
            ) catch return false;
            for (path[si..], si..) |byte, index| {
                if (byte != '/') continue;
                appendGlobState(
                    allocator,
                    &pending,
                    visited,
                    path_states,
                    .{ .pattern = pi, .path = index + 1 },
                ) catch return false;
            }
            continue;
        }
        var end = si;
        while (end <= path.len) : (end += 1) {
            appendGlobState(
                allocator,
                &pending,
                visited,
                path_states,
                .{ .pattern = pi, .path = end },
            ) catch return false;
            if (end == path.len or (!double and path[end] == '/')) break;
        }
    }
    return false;
}

pub fn codexSchemaProblemAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    codex_path: []const u8,
    out_dir: []const u8,
) !?[]u8 {
    const generation = try generateCodexSchema(allocator, io, codex_path, out_dir);
    defer allocator.free(generation.version);
    if (!generation.success) return problemAlloc(
        allocator,
        "installed Codex {s}: schema generation failed",
        generation.version,
    );
    const missing_aggregate = "installed Codex {s}: missing schema bundle " ++
        "codex_app_server_protocol.schemas.json";
    const aggregate = readSchema(
        allocator,
        io,
        out_dir,
        "codex_app_server_protocol.schemas.json",
    ) catch return problemAlloc(allocator, missing_aggregate, generation.version);
    defer allocator.free(aggregate);
    const missing_v2 = "installed Codex {s}: missing schema bundle " ++
        "codex_app_server_protocol.v2.schemas.json";
    const v2 = readSchema(
        allocator,
        io,
        out_dir,
        "codex_app_server_protocol.v2.schemas.json",
    ) catch return problemAlloc(allocator, missing_v2, generation.version);
    defer allocator.free(v2);
    var aggregate_json = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        aggregate,
        .{},
    ) catch return problemAlloc(
        allocator,
        "installed Codex {s}: invalid app-server schema bundle",
        generation.version,
    );
    defer aggregate_json.deinit();
    const invalid_v2 = "installed Codex {s}: invalid app-server v2 schema bundle";
    var v2_json = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        v2,
        .{},
    ) catch return problemAlloc(allocator, invalid_v2, generation.version);
    defer v2_json.deinit();
    return validateCodexSchemas(
        allocator,
        io,
        out_dir,
        generation.version,
        aggregate_json.value,
        v2_json.value,
    );
}

fn problemAlloc(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    version: []const u8,
) !?[]u8 {
    return @as(?[]u8, try std.fmt.allocPrint(allocator, format, .{version}));
}

const SchemaGeneration = struct { version: []u8, success: bool };

fn generateCodexSchema(
    allocator: std.mem.Allocator,
    io: std.Io,
    codex_path: []const u8,
    out_dir: []const u8,
) !SchemaGeneration {
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    const generated = try std.process.run(allocator, io, .{ .argv = &.{
        codex_path,
        "app-server",
        "generate-json-schema",
        "--experimental",
        "--out",
        out_dir,
    } });
    defer allocator.free(generated.stdout);
    defer allocator.free(generated.stderr);
    const version_result = try std.process.run(
        allocator,
        io,
        .{ .argv = &.{ codex_path, "--version" } },
    );
    defer allocator.free(version_result.stderr);
    const version = try allocator.dupe(
        u8,
        std.mem.trim(u8, version_result.stdout, "\r\n"),
    );
    allocator.free(version_result.stdout);
    return .{
        .version = version,
        .success = generated.term == .exited and generated.term.exited == 0,
    };
}

fn validateCodexSchemas(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    version: []const u8,
    aggregate: std.json.Value,
    v2: std.json.Value,
) !?[]u8 {
    if (try validateCodexMethods(allocator, version, aggregate, v2)) |problem| return problem;
    if (try validateThreadSchemas(allocator, io, out_dir, version)) |problem| return problem;
    if (try validateTurnSchemas(allocator, io, out_dir, version)) |problem| return problem;
    return validateApprovalSchemas(allocator, io, out_dir, version);
}

fn validateCodexMethods(
    allocator: std.mem.Allocator,
    version: []const u8,
    aggregate: std.json.Value,
    v2: std.json.Value,
) !?[]u8 {
    const methods = [_][]const u8{
        "initialize",
        "initialized",
        "thread/start",
        "thread/fork",
        "turn/start",
        "turn/steer",
        "turn/interrupt",
        "thread/inject_items",
        "item/tool/call",
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
    };
    for (methods) |method| if (!containsExactString(aggregate, method) and
        !containsExactString(v2, method)) return @as(
        ?[]u8,
        try std.fmt.allocPrint(
            allocator,
            "installed Codex {s}: missing app-server surface {s}",
            .{ version, method },
        ),
    );
    return null;
}

fn validateThreadSchemas(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    version: []const u8,
) !?[]u8 {
    const fork = readSchema(allocator, io, out_dir, "v2/ThreadForkParams.json") catch return @as(
        ?[]u8,
        try std.fmt.allocPrint(
            allocator,
            "installed Codex {s}: missing thread/fork schema",
            .{version},
        ),
    );
    defer allocator.free(fork);
    if (!schemaHasRootProperties(
        allocator,
        fork,
        &.{ "lastTurnId", "ephemeral", "approvalPolicy", "sandbox" },
    )) return @as(
        ?[]u8,
        try std.fmt.allocPrint(
            allocator,
            "installed Codex {s}: thread/fork missing required properties",
            .{version},
        ),
    );
    const start = readSchema(allocator, io, out_dir, "v2/ThreadStartParams.json") catch return @as(
        ?[]u8,
        try std.fmt.allocPrint(
            allocator,
            "installed Codex {s}: missing thread/start schema",
            .{version},
        ),
    );
    defer allocator.free(start);
    if (!schemaHasRootProperties(
        allocator,
        start,
        &.{ "dynamicTools", "approvalPolicy", "sandbox" },
    )) return @as(
        ?[]u8,
        try std.fmt.allocPrint(
            allocator,
            "installed Codex {s}: thread/start missing required properties",
            .{version},
        ),
    );
    return null;
}

fn schemaHasRootProperties(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    required_properties: []const []const u8,
) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const properties = parsed.value.object.get("properties") orelse return false;
    if (properties != .object) return false;
    for (required_properties) |name| if (!properties.object.contains(name)) return false;
    return true;
}

fn validateTurnSchemas(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    version: []const u8,
) !?[]u8 {
    const turn = readSchema(allocator, io, out_dir, "v2/TurnStartParams.json") catch return @as(
        ?[]u8,
        try std.fmt.allocPrint(
            allocator,
            "installed Codex {s}: missing turn/start schema",
            .{version},
        ),
    );
    defer allocator.free(turn);
    var turn_schema = std.json.parseFromSlice(std.json.Value, allocator, turn, .{}) catch
        return @as(
            ?[]u8,
            try std.fmt.allocPrint(
                allocator,
                "installed Codex {s}: invalid TurnStartParams schema",
                .{version},
            ),
        );
    defer turn_schema.deinit();
    if (!hasCompleteSkillInput(turn_schema.value, false)) {
        const message = "installed Codex {s}: SkillUserInput must require name, path, and type";
        return @as(?[]u8, try std.fmt.allocPrint(allocator, message, .{version}));
    }
    const notification_files = [_][]const u8{
        "v2/ThreadStartedNotification.json",
        "v2/TurnStartedNotification.json",
        "v2/TurnCompletedNotification.json",
        "v2/ItemStartedNotification.json",
        "v2/AgentMessageDeltaNotification.json",
    };
    for (notification_files) |file| {
        const bytes = readSchema(allocator, io, out_dir, file) catch return @as(
            ?[]u8,
            try std.fmt.allocPrint(
                allocator,
                "installed Codex {s}: missing notification family {s}",
                .{ version, file },
            ),
        );
        allocator.free(bytes);
    }
    return null;
}

fn validateApprovalSchemas(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    version: []const u8,
) !?[]u8 {
    for (approval_schemas) |approval| {
        const bytes = readSchema(allocator, io, out_dir, approval.file) catch return @as(
            ?[]u8,
            try std.fmt.allocPrint(
                allocator,
                "installed Codex {s}: missing approval schema {s}",
                .{ version, approval.file },
            ),
        );
        defer allocator.free(bytes);
        var schema_json = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
            return @as(
                ?[]u8,
                try std.fmt.allocPrint(
                    allocator,
                    "installed Codex {s}: invalid approval schema {s}",
                    .{ version, approval.file },
                ),
            );
        defer schema_json.deinit();
        if (!approvalSchemaHas(
            schema_json.value,
            approval.properties,
            approval.required,
            approval.value_property,
            approval.values,
        )) return @as(
            ?[]u8,
            try std.fmt.allocPrint(
                allocator,
                "installed Codex {s}: incompatible approval schema {s}",
                .{ version, approval.file },
            ),
        );
    }
    return null;
}

fn approvalSchemaHas(
    value: std.json.Value,
    properties: []const []const u8,
    required: []const []const u8,
    value_property: ?[]const u8,
    values: []const []const u8,
) bool {
    if (value != .object) return false;
    const property_map = value.object.get("properties") orelse return false;
    if (property_map != .object) return false;
    for (properties) |name| if (!property_map.object.contains(name)) return false;
    const required_values = value.object.get("required") orelse return false;
    if (required_values != .array) return false;
    for (required) |name| {
        var found = false;
        for (required_values.array.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    if (values.len > 0) {
        const property_name = value_property orelse return false;
        const property = property_map.object.get(property_name) orelse return false;
        for (values) |expected| {
            if (!schemaPropertyHasEnumValue(value, property, expected, 0)) return false;
        }
    }
    return true;
}

fn schemaPropertyHasEnumValue(
    root: std.json.Value,
    node: std.json.Value,
    expected: []const u8,
    initial_depth: u8,
) bool {
    const Pending = struct { value: std.json.Value, depth: u8 };
    var pending: [64]Pending = undefined;
    var pending_len: usize = 1;
    pending[0] = .{ .value = node, .depth = initial_depth };
    while (pending_len > 0) {
        pending_len -= 1;
        const current = pending[pending_len];
        if (current.depth >= 16 or current.value != .object) continue;
        if (current.value.object.get("enum")) |enum_value| {
            if (enum_value == .array) for (enum_value.array.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, expected)) return true;
            };
        }
        if (current.value.object.get("$ref")) |ref| {
            if (resolveSchemaDefinition(root, ref)) |target| {
                if (pending_len == pending.len) return false;
                pending[pending_len] = .{ .value = target, .depth = current.depth + 1 };
                pending_len += 1;
            }
        }
        for ([_][]const u8{ "oneOf", "anyOf", "allOf" }) |keyword| {
            const branches = current.value.object.get(keyword) orelse continue;
            if (branches != .array) continue;
            for (branches.array.items) |branch| {
                if (pending_len == pending.len) return false;
                pending[pending_len] = .{ .value = branch, .depth = current.depth + 1 };
                pending_len += 1;
            }
        }
    }
    return false;
}

fn resolveSchemaDefinition(root: std.json.Value, ref: std.json.Value) ?std.json.Value {
    if (ref != .string or !std.mem.startsWith(u8, ref.string, "#/definitions/")) return null;
    const definitions = root.object.get("definitions") orelse return null;
    if (definitions != .object) return null;
    return definitions.object.get(ref.string["#/definitions/".len..]);
}

fn containsExactString(value: std.json.Value, needle: []const u8) bool {
    var pending: [4096]std.json.Value = undefined;
    var pending_len: usize = 1;
    pending[0] = value;
    while (pending_len > 0) {
        pending_len -= 1;
        switch (pending[pending_len]) {
            .string => |text| if (std.mem.eql(u8, text, needle)) return true,
            .array => |array| for (array.items) |item| {
                if (pending_len == pending.len) return false;
                pending[pending_len] = item;
                pending_len += 1;
            },
            .object => |object| {
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    if (pending_len == pending.len) return false;
                    pending[pending_len] = entry.value_ptr.*;
                    pending_len += 1;
                }
            },
            else => {},
        }
    }
    return false;
}

fn hasCompleteSkillInput(value: std.json.Value, named_skill: bool) bool {
    const Node = struct { value: std.json.Value, named_skill: bool };
    var pending: [4096]Node = undefined;
    var pending_len: usize = 1;
    pending[0] = .{ .value = value, .named_skill = named_skill };
    while (pending_len > 0) {
        pending_len -= 1;
        const node = pending[pending_len];
        switch (node.value) {
            .object => |object| {
                var is_skill = node.named_skill;
                if (object.get("title")) |title| if (title == .string and std.mem.eql(
                    u8,
                    title.string,
                    "SkillUserInput",
                )) {
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
                    if (name and path and kind) return true;
                };
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    if (pending_len == pending.len) return false;
                    pending[pending_len] = .{
                        .value = entry.value_ptr.*,
                        .named_skill = std.mem.eql(u8, entry.key_ptr.*, "SkillUserInput"),
                    };
                    pending_len += 1;
                }
            },
            .array => |array| for (array.items) |item| {
                if (pending_len == pending.len) return false;
                pending[pending_len] = .{ .value = item, .named_skill = false };
                pending_len += 1;
            },
            else => {},
        }
    }
    return false;
}

fn readSchema(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    relative: []const u8,
) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ root, relative });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
}

pub fn validateManifest(allocator: std.mem.Allocator, io: std.Io, skill_root: []const u8) !void {
    const ui_root = try std.fs.path.join(allocator, &.{ skill_root, "assets", "ui" });
    defer allocator.free(ui_root);
    const path = try std.fs.path.join(allocator, &.{ ui_root, "manifest.json" });
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
    const assets = obj.get("assets") orelse return error.InvalidUiManifest;
    if (assets != .array or assets.array.items.len != 2) return error.InvalidUiManifest;
    const expected_assets = [_][]const u8{ "app.css", "app.js" };
    for (assets.array.items, expected_assets) |asset, expected| {
        if (asset != .string or !std.mem.eql(u8, asset.string, expected)) {
            return error.InvalidUiManifest;
        }
    }
    try validateUiFile(allocator, io, ui_root, "index.html");
    for (expected_assets) |asset| try validateUiFile(allocator, io, ui_root, asset);
}

fn validateUiFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    ui_root: []const u8,
    relative: []const u8,
) !void {
    const root_real = std.Io.Dir.cwd().realPathFileAlloc(io, ui_root, allocator) catch
        return error.InvalidUiManifest;
    defer allocator.free(root_real);
    const candidate = try std.fs.path.join(allocator, &.{ ui_root, relative });
    defer allocator.free(candidate);
    const file_real = std.Io.Dir.cwd().realPathFileAlloc(io, candidate, allocator) catch
        return error.InvalidUiManifest;
    defer allocator.free(file_real);
    const confined = std.mem.startsWith(u8, file_real, root_real) and
        file_real.len > root_real.len and file_real[root_real.len] == std.fs.path.sep;
    if (!confined) return error.InvalidUiManifest;
    var file = std.Io.Dir.cwd().openFile(io, file_real, .{ .allow_directory = false }) catch
        return error.InvalidUiManifest;
    file.close(io);
}

fn expectString(obj: std.json.ObjectMap, name: []const u8, expected: []const u8) !void {
    const value = obj.get(name) orelse return error.InvalidUiManifest;
    if (value != .string or !std.mem.eql(u8, value.string, expected)) {
        return error.InvalidUiManifest;
    }
}

test "manifest contract rejects ABI drift" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"schema\":\"synoptic-ui-manifest/v1\"}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.InvalidUiManifest,
        expectString(parsed.value.object, "uiAbi", ui_abi),
    );
}

test "manifest contract requires the declared confined UI files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "skill/assets/ui");
    const root = try tmp.dir.realPathFileAlloc(io, "skill", allocator);
    defer allocator.free(root);
    const manifest = "{\"schema\":\"synoptic-ui-manifest/v1\",\"uiAbi\":" ++
        "\"synoptic-ui/v1\",\"requiredSkillAbi\":\"synoptic-skill-abi/v1\"," ++
        "\"entry\":\"index.html\",\"assets\":[\"app.css\",\"app.js\"]}";
    try tmp.dir.writeFile(io, .{
        .sub_path = "skill/assets/ui/manifest.json",
        .data = manifest,
    });
    for ([_][2][]const u8{
        .{ "skill/assets/ui/index.html", "<title>Synoptic</title>" },
        .{ "skill/assets/ui/app.css", "body{}" },
        .{ "skill/assets/ui/app.js", "'use strict';" },
    }) |file| try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    try validateManifest(allocator, io, root);
    try tmp.dir.deleteFile(io, "skill/assets/ui/app.js");
    try std.testing.expectError(
        error.InvalidUiManifest,
        validateManifest(allocator, io, root),
    );
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
    const script = "#!/bin/sh\nset -eu\nif [ \"${1:-}\" = --version ]; the" ++
        "n echo 'codex-test 9'; exit 0; fi\nout=''\nwhile [ $# " ++
        "-gt 0 ]; do if [ \"$1\" = --out ]; then shift; out=\"$" ++
        "1\"; fi; shift; done\nmkdir -p \"$out/v2\"\necho '{\"m" ++
        "ethods\":[\"initialize\"]}' > \"$out/codex_app_server_" ++
        "protocol.schemas.json\"\ncp \"$out/codex_app_server_pr" ++
        "otocol.schemas.json\" \"$out/codex_app_server_protocol" ++
        ".v2.schemas.json\"\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "codex", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        script_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
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
        \\printf '%s' '{"properties":{"lastTurnId":{},"ephemeral":{},"approvalPolicy":{},"sandbox":{}}}' > "$out/v2/ThreadForkParams.json"
        \\printf '%s' '{"properties":{"dynamicTools":{},"approvalPolicy":{},"sandbox":{}}}' > "$out/v2/ThreadStartParams.json"
        \\printf '%s' '{"SkillUserInput":{"required":["name","path","type"]}}' > "$out/v2/TurnStartParams.json"
        \\for f in ThreadStartedNotification TurnStartedNotification TurnCompletedNotification ItemStartedNotification AgentMessageDeltaNotification; do printf '%s' '{}' > "$out/v2/$f.json"; done
        \\printf '%s' '{"properties":{"threadId":{},"availableDecisions":{}},"required":["threadId"]}' > "$out/CommandExecutionRequestApprovalParams.json"
        \\printf '%s' '{"properties":{"decision":{"$ref":"#/definitions/Decision"}},"required":["decision"],"definitions":{"Decision":{"enum":["accept","acceptForSession","decline","cancel"]}}}' > "$out/CommandExecutionRequestApprovalResponse.json"
        \\printf '%s' '{"properties":{"decision":{"enum":["decline"]}},"required":["decision"]}' > "$out/FileChangeRequestApprovalResponse.json"
        \\printf '%s' '{"properties":{"threadId":{},"permissions":{}},"required":["threadId","permissions"]}' > "$out/PermissionsRequestApprovalParams.json"
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "codex", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        script_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    const schema = try std.fs.path.join(allocator, &.{ root, "schema" });
    defer allocator.free(schema);
    const problem = (try codexSchemaProblemAlloc(allocator, io, script_path, schema)).?;
    defer allocator.free(problem);
    try std.testing.expect(std.mem.indexOf(u8, problem, "codex-test approvals") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        problem,
        "PermissionsRequestApprovalResponse.json",
    ) != null);
}

test "empty config roots never resolve relative repository paths" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("XDG_CONFIG_HOME", "");
    try environment.put("HOME", "");
    try std.testing.expect(try configPathAlloc(std.testing.allocator, &environment) == null);
    try environment.put("HOME", "/safe-home");
    const path = (try configPathAlloc(std.testing.allocator, &environment)).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/safe-home/.config/synoptic/config.toml", path);

    try environment.put("XDG_CONFIG_HOME", ".config");
    const fallback = (try configPathAlloc(std.testing.allocator, &environment)).?;
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("/safe-home/.config/synoptic/config.toml", fallback);
    try environment.put("HOME", "relative-home");
    try std.testing.expect(try configPathAlloc(std.testing.allocator, &environment) == null);
}

test "schema validation ignores required field names outside root properties" {
    const raw =
        "{\"description\":\"lastTurnId ephemeral\"," ++
        "\"properties\":{\"approvalPolicy\":{},\"sandbox\":{}}}";
    try std.testing.expect(!schemaHasRootProperties(
        std.testing.allocator,
        raw,
        &.{ "lastTurnId", "ephemeral", "approvalPolicy", "sandbox" },
    ));
}

test "approval values must belong to the declared response property" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"properties\":{\"decision\":{},\"unrelated\":{\"enum\":[\"decline\"]}}," ++
            "\"required\":[\"decision\"]}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(!approvalSchemaHas(
        parsed.value,
        &.{"decision"},
        &.{"decision"},
        "decision",
        &.{"decline"},
    ));
}

test "globstar slash consumes only complete path segments" {
    try std.testing.expect(globMatches(
        std.testing.allocator,
        "**/__snapshots__/**",
        "src/__snapshots__/x.snap",
    ));
    try std.testing.expect(globMatches(
        std.testing.allocator,
        "**/__snapshots__/**",
        "__snapshots__/x.snap",
    ));
    try std.testing.expect(!globMatches(
        std.testing.allocator,
        "**/__snapshots__/**",
        "src/not__snapshots__/ordinary.zig",
    ));
}

test "overlapping stars visit each glob state at most once" {
    const repeated = "*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b";
    try std.testing.expect(!globMatches(
        std.testing.allocator,
        repeated,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ));
}
