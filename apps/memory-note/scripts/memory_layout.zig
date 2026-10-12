const std = @import("std");

// Configuration is read by Codex, which owns layering, profiles, and project trust.
// This client requests no thread, turn, tool, or model execution.
const config_bytes_max = 1024 * 1024;
const config_messages_max = 128;
const config_timeout_seconds = 10;

pub const Version = enum {
    v1,
    v2,

    pub fn parse(value: []const u8) !Version {
        return std.meta.stringToEnum(Version, value) orelse error.InvalidMemoryVersion;
    }

    pub fn directory(self: Version) []const u8 {
        return switch (self) {
            .v1 => "memories",
            .v2 => "memories_v2",
        };
    }
};

/// The caller validates the home directory before querying Codex configuration.
pub fn selectedVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    home: []const u8,
    explicit_version: ?Version,
) !Version {
    if (!std.fs.path.isAbsolute(home)) return error.InvalidCodexHome;
    if (explicit_version) |version| return version;
    var child_env = try env.clone(allocator);
    defer child_env.deinit();
    try child_env.put("CODEX_HOME", home);
    const executable = env.get("CODEX_BIN") orelse "codex";
    var child = std.process.spawn(io, .{
        .argv = &.{ executable, "app-server" },
        .environ_map = &child_env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.CodexConfigUnavailable,
        else => return err,
    };
    defer retireConfigChild(io, &child);
    var buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(allocator, io, buffer.toStreams(), &.{child.stdout.?});
    defer reader.deinit();
    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .fromSeconds(config_timeout_seconds),
        .clock = .awake,
    } };
    const deadline = timeout.toDeadline(io);
    try writeMessage(io, child.stdin.?, initialize_request, deadline);
    var total_bytes: usize = 0;
    var initialized = try readResponse(allocator, &reader, 1, deadline, &total_bytes);
    initialized.deinit();
    try writeMessage(io, child.stdin.?, "{\"method\":\"initialized\"}\n", deadline);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    const request = try configRequest(allocator, cwd);
    defer allocator.free(request);
    try writeMessage(io, child.stdin.?, request, deadline);
    var response = try readResponse(allocator, &reader, 2, deadline, &total_bytes);
    defer response.deinit();
    return versionFromResponse(response.value);
}

fn retireConfigChild(io: std.Io, child: *std.process.Child) void {
    // Child.kill sends SIGTERM and waits on POSIX. A config subprocess that
    // ignores SIGTERM must not turn the request deadline into an endless wait.
    switch (@import("builtin").os.tag) {
        .windows, .wasi => {},
        else => if (child.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => std.log.warn("could not kill Codex config child: {s}", .{@errorName(err)}),
            };
        },
    }
    child.kill(io);
}

const initialize_request =
    \\{"id":1,"method":"initialize","params":{"clientInfo":{"name":"memory_note","version":"1"},"capabilities":{"experimentalApi":true}}}
    \\
;

fn writeMessage(
    io: std.Io,
    file: std.Io.File,
    message: []const u8,
    deadline: std.Io.Timeout,
) !void {
    if (message.len > std.fs.max_path_bytes * 6 + 1024) return error.ConfigRequestTooLarge;
    var storage: [1]std.Io.Operation.Storage = undefined;
    var batch: std.Io.Batch = .init(&storage);
    defer batch.cancel(io);
    var offset: usize = 0;
    while (offset < message.len) {
        batch.addAt(0, .{ .file_write_streaming = .{
            .file = file,
            .data = &.{message[offset..]},
        } });
        batch.awaitConcurrent(io, deadline) catch |err| switch (err) {
            error.Timeout => return error.CodexConfigTimeout,
            else => return err,
        };
        const completed = batch.next() orelse return error.CodexConfigUnavailable;
        const written = try completed.result.file_write_streaming;
        if (written == 0) return error.CodexConfigUnavailable;
        offset += written;
    }
}

fn configRequest(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(.{
        .id = 2,
        .method = "config/read",
        .params = .{ .includeLayers = false, .cwd = cwd },
    }, .{}, &output.writer);
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

fn readResponse(
    allocator: std.mem.Allocator,
    reader: *std.Io.File.MultiReader,
    expected_id: i64,
    deadline: std.Io.Timeout,
    total_bytes: *usize,
) !std.json.Parsed(std.json.Value) {
    for (0..config_messages_max) |_| {
        const line = try readLine(reader, deadline, total_bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidCodexConfigResponse,
        };
        errdefer parsed.deinit();
        if (parsed.value != .object) return error.InvalidCodexConfigResponse;
        const fields = parsed.value.object;
        if (fields.get("id")) |id| {
            if (id != .integer or id.integer != expected_id)
                return error.InvalidCodexConfigResponse;
            if (fields.contains("error")) return error.CodexConfigRejected;
            const result = fields.get("result") orelse return error.InvalidCodexConfigResponse;
            if (result != .object) return error.InvalidCodexConfigResponse;
            return parsed;
        }
        // Notifications are bounded and carry no configuration authority.
        const method = fields.get("method") orelse return error.InvalidCodexConfigResponse;
        if (method != .string) return error.InvalidCodexConfigResponse;
        parsed.deinit();
    }
    return error.TooManyConfigMessages;
}

fn readLine(
    reader: *std.Io.File.MultiReader,
    deadline: std.Io.Timeout,
    total_bytes: *usize,
) ![]const u8 {
    const stream = reader.reader(0);
    for (0..config_bytes_max + 1) |_| {
        const bytes = stream.buffered();
        if (bytes.len > config_bytes_max - total_bytes.*)
            return error.CodexConfigTooLarge;
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |end| {
            total_bytes.* += end + 1;
            stream.toss(end + 1);
            return bytes[0..end];
        }
        reader.fill(1, deadline) catch |err| switch (err) {
            error.EndOfStream => return error.CodexConfigUnavailable,
            error.Timeout => return error.CodexConfigTimeout,
            else => return err,
        };
        try reader.checkAnyError();
    }
    return error.CodexConfigTooLarge;
}

fn versionFromResponse(response: std.json.Value) !Version {
    const result = try objectField(response, "result");
    const config = try objectField(result, "config");
    const memories = config.object.get("memories") orelse return .v1;
    // Codex 0.162.1 config/read serializes optional TOML settings as JSON null.
    if (memories == .null) return .v1;
    if (memories != .object) return error.InvalidCodexConfigResponse;
    const version = memories.object.get("version") orelse return .v1;
    if (version == .null) return .v1;
    if (version != .string) return error.InvalidCodexConfigResponse;
    return Version.parse(version.string);
}

fn objectField(parent: std.json.Value, key: []const u8) !std.json.Value {
    if (parent != .object) return error.InvalidCodexConfigResponse;
    const value = parent.object.get(key) orelse return error.InvalidCodexConfigResponse;
    if (value != .object) return error.InvalidCodexConfigResponse;
    return value;
}

/// Check the selected spelling without creating directories or hiding symlinks.
/// Absence is a valid empty source; non-directory and symlink ancestors are not.
pub fn validateDirectory(io: std.Io, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    var parts = std.fs.path.componentIterator(path);
    while (parts.next()) |part| {
        const info = std.Io.Dir.cwd().statFile(io, part.path, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (info.kind == .sym_link) return error.SymlinkComponent;
        if (info.kind != .directory) return error.NotDir;
    }
}

test "effective memory version accepts both layouts and Codex's default" {
    const cases = .{
        .{ "{\"result\":{\"config\":{}}}", Version.v1 },
        .{ "{\"result\":{\"config\":{\"memories\":null}}}", Version.v1 },
        .{ "{\"result\":{\"config\":{\"memories\":{}}}}", Version.v1 },
        .{ "{\"result\":{\"config\":{\"memories\":{\"version\":null}}}}", Version.v1 },
        .{ "{\"result\":{\"config\":{\"memories\":{\"version\":\"v1\"}}}}", Version.v1 },
        .{ "{\"result\":{\"config\":{\"memories\":{\"version\":\"v2\"}}}}", Version.v2 },
    };
    inline for (cases) |case| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            case[0],
            .{},
        );
        defer parsed.deinit();
        try std.testing.expectEqual(case[1], try versionFromResponse(parsed.value));
    }
}

test "missing or malformed configuration never guesses a memory root" {
    const cases = [_][]const u8{
        "{}",
        "{\"result\":{}}",
        "{\"result\":{\"config\":null}}",
        "{\"result\":{\"config\":{\"memories\":false}}}",
        "{\"result\":{\"config\":{\"memories\":[]}}}",
        "{\"result\":{\"config\":{\"memories\":{\"version\":2}}}}",
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            case,
            .{},
        );
        defer parsed.deinit();
        try std.testing.expectError(
            error.InvalidCodexConfigResponse,
            versionFromResponse(parsed.value),
        );
    }
    try std.testing.expectError(error.InvalidMemoryVersion, Version.parse("v3"));
    try std.testing.expectError(error.InvalidMemoryVersion, Version.parse(""));
}

const config_server_fixture =
    \\#!/bin/sh
    \\[ "$1" = app-server ] || exit 3
    \\[ "$CODEX_HOME" = "$EXPECTED_HOME" ] || exit 4
    \\IFS= read -r init || exit 5
    \\case "$init" in *'"method":"initialize"'*) ;; *) exit 6 ;; esac
    \\printf '%s\n' '{"method":"notice","params":{}}' '{"id":1,"result":{}}'
    \\IFS= read -r ready || exit 7
    \\[ "$ready" = '{"method":"initialized"}' ] || exit 8
    \\IFS= read -r request || exit 9
    \\case "$request" in *'"method":"config/read"'*'"cwd":"/'*) ;; *) exit 10 ;; esac
    \\printf '%s\n' "$CONFIG_RESPONSE"
    \\IFS= read -r unused
;

fn fixtureSelection(response: []const u8) !Version {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(io, "codex", .{
            .permissions = .fromMode(0o700),
        });
        defer file.close(io);
        try file.writeStreamingAll(io, config_server_fixture);
    }
    const executable = try tmp.dir.realPathFileAlloc(io, "codex", allocator);
    defer allocator.free(executable);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("CODEX_BIN", executable);
    try env.put("CODEX_HOME", "/unselected/home");
    try env.put("EXPECTED_HOME", "/selected/home");
    try env.put("CONFIG_RESPONSE", response);
    return selectedVersion(allocator, io, &env, "/selected/home", null);
}

test "config client initializes and reads effective config for the selected home and cwd" {
    try std.testing.expectEqual(Version.v2, try fixtureSelection(
        "{\"id\":2,\"result\":{\"config\":{\"memories\":{\"version\":\"v2\"}}}}",
    ));
    try std.testing.expectEqual(Version.v1, try fixtureSelection(
        "{\"id\":2,\"result\":{\"config\":{}}}",
    ));
}

test "config client rejects RPC failures malformed results and mismatched identities" {
    try std.testing.expectError(error.CodexConfigRejected, fixtureSelection(
        "{\"id\":2,\"error\":{\"code\":-1,\"message\":\"bad config\"}}",
    ));
    try std.testing.expectError(error.InvalidCodexConfigResponse, fixtureSelection(
        "{\"id\":3,\"result\":{\"config\":{}}}",
    ));
    try std.testing.expectError(error.InvalidCodexConfigResponse, fixtureSelection(
        "{\"id\":2,\"result\":{}}",
    ));
}

test "explicit session version does not require Codex and relative homes are rejected" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("CODEX_BIN", "/missing/codex");
    try std.testing.expectEqual(Version.v2, try selectedVersion(
        std.testing.allocator,
        std.testing.io,
        &env,
        "/selected/home",
        .v2,
    ));
    try std.testing.expectError(error.InvalidCodexHome, selectedVersion(
        std.testing.allocator,
        std.testing.io,
        &env,
        "relative",
        .v2,
    ));
    try std.testing.expectError(error.CodexConfigUnavailable, selectedVersion(
        std.testing.allocator,
        std.testing.io,
        &env,
        "/selected/home",
        null,
    ));
}
