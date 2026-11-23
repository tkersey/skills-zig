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
    var root = Io.Dir.cwd().openDir(io, root_path, .{ .follow_symlinks = false }) catch |err| {
        return mapError(d, null, "subject root", err);
    };
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
    const before = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| {
        return mapError(d, loc, "subject artifact", err);
    };
    if (before.kind != .file) {
        return d.fail(.identity_mismatch, loc, "subject: artifact is not a regular file", .{});
    }
    const file = dir.openFile(io, name, .{
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch |err| return mapError(d, loc, "subject artifact", err);
    defer file.close(io);
    return hashFile(io, d, file, before, artifact, loc, buffer);
}

fn hashFile(
    io: Io,
    d: *Diagnostic,
    file: Io.File,
    before: Io.File.Stat,
    artifact: documents.Artifact,
    loc: *const Loc,
    buffer: *[limits.hash_buffer_bytes]u8,
) diag.Error!u64 {
    const opened = file.stat(io) catch |err| return mapError(d, loc, "subject artifact", err);
    if (opened.kind != .file or opened.inode != before.inode) {
        return d.fail(
            .identity_mismatch,
            loc,
            "subject: artifact was replaced during verification",
            .{},
        );
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
    const reads_max = artifact.size_bytes / limits.hash_buffer_bytes + 2;
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

fn subjectFor(
    path: []const u8,
    bytes: []const u8,
    storage: *[1]documents.Artifact,
) documents.Subject {
    const hex = assess.sha256Hex(bytes);
    storage[0] = .{
        .id = "a",
        .role = .context,
        .path = path,
        .sha256 = &hex,
        .size_bytes = bytes.len,
    };
    return .{ .id = "s", .context = 0, .artifacts = storage };
}

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
    const subject: documents.Subject = .{ .id = "s", .context = 0, .artifacts = &storage };
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
