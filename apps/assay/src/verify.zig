const std = @import("std");
const limits = @import("limits.zig");
const diag = @import("diag.zig");
const documents = @import("documents.zig");
const assess = @import("assess.zig");

const Io = std.Io;
const Loc = diag.Loc;
const Diagnostic = diag.Diagnostic;

pub const Status = enum { not_checked, matched_manifest_during_this_invocation };

pub const Verification = struct {
    status: Status = .not_checked,
    files_checked: u64 = 0,
    bytes_read: u64 = 0,
};

pub fn verify(
    io: Io,
    d: *Diagnostic,
    root_path: []const u8,
    subject: documents.Subject,
    buffer: *[limits.hash_buffer_bytes]u8,
) diag.Error!Verification {
    var root = try openRoot(io, d, root_path);
    defer root.close(io);
    var result: Verification = .{ .status = .matched_manifest_during_this_invocation };
    const list_loc = Loc.root.key("artifacts");
    for (subject.artifacts, 0..) |artifact, index| {
        const item_loc = list_loc.index(index);
        const loc = item_loc.key("path");
        result.bytes_read += try verifyArtifact(io, d, root, artifact, &loc, buffer);
        result.files_checked += 1;
    }
    std.debug.assert(result.bytes_read == subject.bytesDeclared());
    return result;
}

fn openRoot(io: Io, d: *Diagnostic, root_path: []const u8) diag.Error!Io.Dir {
    if (root_path.len == 0 or root_path.len > limits.path_bytes_max) {
        return d.fail(.invalid_usage, null, "--subject-root must be a nonempty bounded path", .{});
    }
    const absolute = root_path[0] == '/';
    const start: []const u8 = if (absolute) "/" else ".";
    var current = Io.Dir.cwd().openDir(io, start, .{}) catch |err| {
        return mapError(d, null, "subject root", err);
    };
    errdefer current.close(io);
    var components = std.mem.splitScalar(u8, root_path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            const message = "--subject-root must not contain .. components";
            return d.fail(.invalid_usage, null, message, .{});
        }
        const next = current.openDir(io, component, .{ .follow_symlinks = false }) catch |err| {
            return mapError(d, null, "subject root component", err);
        };
        current.close(io);
        current = next;
    }
    return current;
}

fn verifyArtifact(
    io: Io,
    d: *Diagnostic,
    root: Io.Dir,
    artifact: documents.Artifact,
    loc: *const Loc,
    buffer: *[limits.hash_buffer_bytes]u8,
) diag.Error!u64 {
    std.debug.assert(documents.isRelativePath(artifact.path));
    const split = std.mem.lastIndexOfScalar(u8, artifact.path, '/');
    const name = if (split) |position| artifact.path[position + 1 ..] else artifact.path;
    var parent: ?Io.Dir = null;
    defer if (parent) |dir| dir.close(io);
    if (split) |position| {
        var components = std.mem.splitScalar(u8, artifact.path[0..position], '/');
        while (components.next()) |component| {
            const base = parent orelse root;
            const next = base.openDir(io, component, .{ .follow_symlinks = false }) catch |err| {
                return mapError(d, loc, "subject artifact directory", err);
            };
            if (parent) |previous| previous.close(io);
            parent = next;
        }
    }
    const dir = parent orelse root;
    const file = openArtifact(dir, name) catch |err| {
        return mapError(d, loc, "subject artifact", err);
    };
    defer file.close(io);
    return hashFile(io, d, file, artifact, loc, buffer);
}

fn openArtifact(dir: Io.Dir, name: []const u8) std.posix.OpenError!Io.File {
    const handle = try std.posix.openat(dir.handle, name, .{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0);
    return .{ .handle = handle, .flags = .{ .nonblocking = true } };
}

fn hashFile(
    io: Io,
    d: *Diagnostic,
    file: Io.File,
    artifact: documents.Artifact,
    loc: *const Loc,
    buffer: *[limits.hash_buffer_bytes]u8,
) diag.Error!u64 {
    const opened = file.stat(io) catch |err| return mapError(d, loc, "subject artifact", err);
    if (opened.kind != .file) {
        return d.fail(.identity_mismatch, loc, "subject: artifact is not a regular file", .{});
    }
    if (opened.size != artifact.size_bytes) {
        return d.fail(
            .identity_mismatch,
            loc,
            "subject: artifact length differs from manifest",
            .{},
        );
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    const reads_max = artifact.size_bytes + 2;
    var reads: u64 = 0;
    while (reads < reads_max) : (reads += 1) {
        const count = file.readPositional(io, &.{buffer}, offset) catch |err| {
            return mapError(d, loc, "subject artifact", err);
        };
        if (count == 0) break;
        offset += count;
        if (offset > artifact.size_bytes) break;
        hasher.update(buffer[0..count]);
    } else return d.fail(
        .identity_mismatch,
        loc,
        "subject: artifact changed during verification",
        .{},
    );
    const after = file.stat(io) catch |err| return mapError(d, loc, "subject artifact", err);
    if (offset != artifact.size_bytes or changed(opened, after)) {
        return d.fail(
            .identity_mismatch,
            loc,
            "subject: artifact changed during verification",
            .{},
        );
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, artifact.sha256)) {
        return d.fail(
            .identity_mismatch,
            loc,
            "subject: artifact digest differs from manifest",
            .{},
        );
    }
    return offset;
}

pub fn changed(before: Io.File.Stat, after: Io.File.Stat) bool {
    return before.inode != after.inode or before.size != after.size or
        before.mtime.nanoseconds != after.mtime.nanoseconds or
        before.ctime.nanoseconds != after.ctime.nanoseconds;
}

fn mapError(d: *Diagnostic, loc: ?*const Loc, label: []const u8, err: anyerror) error{Rejected} {
    return switch (err) {
        error.FileNotFound => d.fail(.missing_input, loc, "{s} not found", .{label}),
        error.SymLinkLoop, error.NotDir, error.IsDir => d.fail(
            .identity_mismatch,
            loc,
            "{s} is a symbolic link or has an unexpected file type",
            .{label},
        ),
        else => d.fail(.io_error, loc, "{s} could not be read: {s}", .{ label, @errorName(err) }),
    };
}

const testing = std.testing;

test "file verification matches regular files and rejects substitution" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "dir", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "dir/file", .data = "payload" });
    try tmp.dir.symLink(io, "dir", "alias", .{ .is_directory = true });
    try tmp.dir.symLink(io, "file", "dir/link", .{});
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    var buffer: [limits.hash_buffer_bytes]u8 = undefined;
    var storage: [1]documents.Artifact = undefined;
    const hex = assess.sha256Hex("payload");
    storage[0] = .{
        .id = "a",
        .role = .context,
        .path = "dir/file",
        .sha256 = &hex,
        .size_bytes = 7,
    };
    const subject: documents.Subject = .{
        .id = "s",
        .context = 0,
        .artifacts = &storage,
        .artifact_ids = .empty,
    };
    var d: Diagnostic = .{};
    const result = try verify(io, &d, root, subject, &buffer);
    try testing.expectEqual(@as(u64, 7), result.bytes_read);
    try testing.expectEqual(@as(u64, 1), result.files_checked);
    const cases = [_]struct { path: []const u8, size: u64, code: diag.Code }{
        .{ .path = "alias/file", .size = 7, .code = .identity_mismatch },
        .{ .path = "dir/link", .size = 7, .code = .identity_mismatch },
        .{ .path = "dir/missing", .size = 7, .code = .missing_input },
        .{ .path = "dir", .size = 7, .code = .identity_mismatch },
        .{ .path = "dir/file", .size = 8, .code = .identity_mismatch },
    };
    for (cases) |case| {
        storage[0].path = case.path;
        storage[0].size_bytes = case.size;
        try testing.expectError(error.Rejected, verify(io, &d, root, subject, &buffer));
        try testing.expectEqual(case.code, d.code);
        try testing.expectEqualStrings("/artifacts/0/path", d.location().?);
    }
    storage[0] = .{
        .id = "a",
        .role = .context,
        .path = "dir/file",
        .sha256 = &hex,
        .size_bytes = 7,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "dir/file", .data = "PAYLOAD" });
    try testing.expectError(error.Rejected, verify(io, &d, root, subject, &buffer));
    try testing.expectEqual(diag.Code.identity_mismatch, d.code);
    const linked_root = try std.fs.path.join(testing.allocator, &.{ root, "alias" });
    defer testing.allocator.free(linked_root);
    storage[0].path = "file";
    try testing.expectError(error.Rejected, verify(io, &d, linked_root, subject, &buffer));
    try testing.expectEqual(diag.Code.identity_mismatch, d.code);
}

test "subject roots reject symbolic links in every spelling" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "dir", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "dir/file", .data = "payload" });
    try tmp.dir.symLink(io, "dir", "alias", .{ .is_directory = true });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const base = root_buffer[0..root_len];
    var buffer: [limits.hash_buffer_bytes]u8 = undefined;
    const hex = assess.sha256Hex("payload");
    var storage = [1]documents.Artifact{.{
        .id = "a",
        .role = .context,
        .path = "file",
        .sha256 = &hex,
        .size_bytes = 7,
    }};
    const subject: documents.Subject = .{
        .id = "s",
        .context = 0,
        .artifacts = &storage,
        .artifact_ids = .empty,
    };
    const cases = [_]struct { suffix: []const u8, code: ?diag.Code }{
        .{ .suffix = "/dir", .code = null },
        .{ .suffix = "/dir/", .code = null },
        .{ .suffix = "/./dir/.", .code = null },
        .{ .suffix = "/alias", .code = .identity_mismatch },
        .{ .suffix = "/alias/", .code = .identity_mismatch },
        .{ .suffix = "/alias/.", .code = .identity_mismatch },
        .{ .suffix = "/dir/../dir", .code = .invalid_usage },
        .{ .suffix = "/absent", .code = .missing_input },
    };
    var d: Diagnostic = .{};
    for (cases) |case| {
        const path = try std.mem.concat(testing.allocator, u8, &.{ base, case.suffix });
        defer testing.allocator.free(path);
        const code = case.code orelse {
            _ = try verify(io, &d, path, subject, &buffer);
            continue;
        };
        try testing.expectError(error.Rejected, verify(io, &d, path, subject, &buffer));
        try testing.expectEqual(code, d.code);
    }
    try testing.expectError(error.Rejected, verify(io, &d, "", subject, &buffer));
    try testing.expectEqual(diag.Code.invalid_usage, d.code);
}

const ShortReads = struct {
    var delegate: *const @TypeOf(std.testing.io.vtable.fileReadPositional) = undefined;
    var calls: usize = 0;

    fn read(
        userdata: ?*anyopaque,
        file: Io.File,
        buffers: []const []u8,
        offset: u64,
    ) Io.File.ReadPositionalError!usize {
        calls += 1;
        const first = buffers[0];
        const limited = [_][]u8{first[0..@min(first.len, 3)]};
        return delegate.*(userdata, file, &limited, offset);
    }
};

test "short positional reads still verify every byte" {
    var vtable = testing.io.vtable.*;
    ShortReads.delegate = &testing.io.vtable.fileReadPositional;
    ShortReads.calls = 0;
    vtable.fileReadPositional = ShortReads.read;
    const io: Io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data: [200 * 1024]u8 = @splat('q');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "large", .data = &data });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const hex = assess.sha256Hex(&data);
    var storage = [1]documents.Artifact{.{
        .id = "a",
        .role = .context,
        .path = "large",
        .sha256 = &hex,
        .size_bytes = data.len,
    }};
    const subject: documents.Subject = .{
        .id = "s",
        .context = 0,
        .artifacts = &storage,
        .artifact_ids = .empty,
    };
    var buffer: [limits.hash_buffer_bytes]u8 = undefined;
    var d: Diagnostic = .{};
    const result = try verify(io, &d, root_buffer[0..root_len], subject, &buffer);
    try testing.expectEqual(@as(u64, data.len), result.bytes_read);
    try testing.expect(ShortReads.calls > data.len / 3);
}

test "visible metadata changes are detected" {
    const base: Io.File.Stat = .{
        .inode = 1,
        .nlink = 1,
        .size = 7,
        .permissions = .default_file,
        .kind = .file,
        .atime = null,
        .mtime = .{ .nanoseconds = 10 },
        .ctime = .{ .nanoseconds = 10 },
        .block_size = 1,
    };
    try testing.expect(!changed(base, base));
    var grown = base;
    grown.size = 8;
    try testing.expect(changed(base, grown));
    var touched = base;
    touched.mtime = .{ .nanoseconds = 11 };
    try testing.expect(changed(base, touched));
    var replaced = base;
    replaced.inode = 2;
    try testing.expect(changed(base, replaced));
}
