const std = @import("std");

pub const PublicationFailure = struct {
    cause: anyerror,
    /// Cleanup is attempted under cancellation protection. A failure can leave
    /// this isolated stage behind; preserve the original operation error too.
    cleanup: ?struct { cause: anyerror, stage_name: [32]u8 } = null,
};

pub const PublicationOutcome = union(enum) {
    complete,
    /// Publication was not attempted; the destination is unchanged.
    not_published: PublicationFailure,
    /// Rename returned an error. The filesystem may have committed the rename
    /// before reporting failure, so callers must not infer an unchanged target.
    publication_unknown: PublicationFailure,
    /// The complete destination is visible, but requested directory sync failed.
    /// Retrying create-new publication will encounter the published destination.
    published_unsynced: anyerror,
};

pub const PublicationOptions = struct {
    permissions: std.Io.File.Permissions = .default_file,
    /// File sync alone preserves the existing publication contract; it does not
    /// promise persistence of the renamed directory entry across a crash.
    durability: enum {
        atomic_visibility,
        file_synced,
        file_and_directories_synced,
    } = .file_synced,
};

/// Publish complete bytes, replacing the destination entry atomically. An
/// existing destination symlink is replaced, never followed.
///
/// Both directories are borrowed, already admitted capabilities. The caller
/// owns path admission, permissions of the directories, stage isolation from
/// inventories, and exclusion of hostile mutation within the staging directory.
/// A validated leaf does not establish custody of an arbitrary pathname.
///
/// The I/O backend must provide atomic rename, including source removal on
/// success. Rename errors preserve publication uncertainty, including a remote
/// filesystem committing before its response is lost.
/// There is no cross-device copy fallback. Strongest-mode success synchronizes
/// both retained directories; persistence of their ancestors is caller-owned.
pub fn publishReplacement(
    io: std.Io,
    staging_dir: std.Io.Dir,
    destination_dir: std.Io.Dir,
    leaf: []const u8,
    parts: []const []const u8,
    options: PublicationOptions,
) PublicationOutcome {
    return publish(true, io, staging_dir, destination_dir, leaf, parts, options);
}

/// Like `publishReplacement`, but an existing destination entry (including a
/// symlink) is preserved and produces the backend's collision error.
/// Requires atomic nonreplacing rename, including source removal on success.
/// Unsupported filesystems report their rename error without copying bytes.
pub fn publishCreateNew(
    io: std.Io,
    staging_dir: std.Io.Dir,
    destination_dir: std.Io.Dir,
    leaf: []const u8,
    parts: []const []const u8,
    options: PublicationOptions,
) PublicationOutcome {
    return publish(false, io, staging_dir, destination_dir, leaf, parts, options);
}

const stage_attempts_max = 16;

const Stage = struct {
    file: std.Io.File,
    name: [32]u8,
    file_open: bool = true,

    fn close(self: *Stage, io: std.Io) void {
        if (self.file_open) {
            self.file.close(io);
            self.file_open = false;
        }
    }

    fn fail(
        self: *Stage,
        io: std.Io,
        directory: std.Io.Dir,
        err: anyerror,
        comptime attempted: bool,
    ) PublicationOutcome {
        self.close(io);
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        var failure: PublicationFailure = .{ .cause = err };
        directory.deleteFile(io, &self.name) catch |cleanup_err| {
            if (cleanup_err != error.FileNotFound)
                failure.cleanup = .{ .cause = cleanup_err, .stage_name = self.name };
        };
        return if (attempted) .{
            .publication_unknown = failure,
        } else .{ .not_published = failure };
    }
};

fn createStage(
    io: std.Io,
    directory: std.Io.Dir,
    leaf: []const u8,
    permissions: std.Io.File.Permissions,
) !Stage {
    for (0..stage_attempts_max) |_| {
        var random: [16]u8 = undefined;
        io.random(&random);
        const name = std.fmt.bytesToHex(random, .lower);
        // The handles can name the same directory, including through aliases.
        // Never make the destination itself visible as an unfinished stage.
        if (std.ascii.eqlIgnoreCase(&name, leaf)) continue;
        const file = directory.createFile(io, &name, .{
            .exclusive = true,
            .truncate = false,
            .permissions = permissions,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return .{ .file = file, .name = name };
    }
    return error.StagingNameExhausted;
}

fn publish(
    comptime replace: bool,
    io: std.Io,
    staging_dir: std.Io.Dir,
    destination_dir: std.Io.Dir,
    leaf: []const u8,
    parts: []const []const u8,
    options: PublicationOptions,
) PublicationOutcome {
    if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..") or
        std.mem.indexOfAny(u8, leaf, "/\\\x00") != null)
    {
        return .{ .not_published = .{ .cause = error.InvalidPath } };
    }
    var stage = createStage(io, staging_dir, leaf, options.permissions) catch |err|
        return .{ .not_published = .{ .cause = err } };
    for (parts) |part| {
        stage.file.writeStreamingAll(io, part) catch |err| return stage.fail(
            io,
            staging_dir,
            err,
            false,
        );
    }
    if (options.durability != .atomic_visibility) {
        stage.file.sync(io) catch |err| return stage.fail(io, staging_dir, err, false);
    }
    stage.close(io);
    if (replace) {
        staging_dir.rename(&stage.name, destination_dir, leaf, io) catch |err|
            return stage.fail(io, staging_dir, err, true);
    } else {
        staging_dir.renamePreserve(&stage.name, destination_dir, leaf, io) catch |err|
            return stage.fail(io, staging_dir, err, true);
    }
    if (options.durability == .file_and_directories_synced) {
        syncDirectory(io, destination_dir) catch |err| return .{ .published_unsynced = err };
        syncDirectory(io, staging_dir) catch |err| return .{ .published_unsynced = err };
    }
    return .complete;
}

fn syncDirectory(io: std.Io, directory: std.Io.Dir) !void {
    const file = try directory.openFile(io, ".", .{
        .allow_directory = true,
        .follow_symlinks = false,
        .path_only = false,
    });
    defer file.close(io);
    try file.sync(io);
}

fn expectContents(directory: std.Io.Dir, leaf: []const u8, expected: []const u8) !void {
    const raw = try directory.readFileAlloc(
        std.testing.io,
        leaf,
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings(expected, raw);
}

fn expectEmpty(directory: std.Io.Dir) !void {
    var entries = directory.iterate();
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try entries.next(std.testing.io));
}

test "staged publication preserves immutable targets and private complete replacements" {
    const io = std.testing.io;
    var staging = std.testing.tmpDir(.{ .iterate = true });
    defer staging.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    const options: PublicationOptions = .{
        .permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
            .fromMode(0o600)
        else
            .default_file,
    };
    try std.testing.expect(
        publishCreateNew(
            io,
            staging.dir,
            destination.dir,
            "entry",
            &.{ "first", "", " bytes" },
            options,
        ) == .complete,
    );
    try std.testing.expectEqual(
        error.PathAlreadyExists,
        publishCreateNew(
            io,
            staging.dir,
            destination.dir,
            "entry",
            &.{"wrong"},
            options,
        ).publication_unknown.cause,
    );
    try expectContents(destination.dir, "entry", "first bytes");
    try std.testing.expect(
        publishReplacement(
            io,
            staging.dir,
            destination.dir,
            "entry",
            &.{ "replacement", " bytes" },
            options,
        ) == .complete,
    );
    try expectContents(destination.dir, "entry", "replacement bytes");
    const stat = try destination.dir.statFile(io, "entry", .{});
    if (@hasDecl(std.Io.File.Permissions, "toMode"))
        try std.testing.expectEqual(
            @as(std.posix.mode_t, 0o600),
            stat.permissions.toMode() & 0o777,
        );
    try expectEmpty(staging.dir);
}

test "staged publication never follows a destination symlink" {
    const io = std.testing.io;
    var staging = std.testing.tmpDir(.{ .iterate = true });
    defer staging.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    try destination.dir.writeFile(io, .{ .sub_path = "target", .data = "untouched" });
    try destination.dir.symLink(io, "target", "entry", .{});
    try std.testing.expectEqual(
        error.PathAlreadyExists,
        publishCreateNew(
            io,
            staging.dir,
            destination.dir,
            "entry",
            &.{"wrong"},
            .{},
        ).publication_unknown.cause,
    );
    try std.testing.expectEqual(
        .sym_link,
        (try destination.dir.statFile(io, "entry", .{ .follow_symlinks = false })).kind,
    );
    try std.testing.expect(
        publishReplacement(io, staging.dir, destination.dir, "entry", &.{"new"}, .{}) == .complete,
    );
    try expectContents(destination.dir, "entry", "new");
    try expectContents(destination.dir, "target", "untouched");
    try expectEmpty(staging.dir);
}

test "staged publication rejects invalid leaf names before creating a file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][]const u8{
        "",
        ".",
        "..",
        "/absolute",
        "nested/leaf",
        "nested\\leaf",
        "nul\x00leaf",
    }) |leaf| {
        try std.testing.expectEqual(
            error.InvalidPath,
            publishCreateNew(
                std.testing.io,
                tmp.dir,
                tmp.dir,
                leaf,
                &.{"bytes"},
                .{},
            ).not_published.cause,
        );
        try std.testing.expectEqual(
            error.InvalidPath,
            publishReplacement(
                std.testing.io,
                tmp.dir,
                tmp.dir,
                leaf,
                &.{"bytes"},
                .{},
            ).not_published.cause,
        );
    }
    try expectEmpty(tmp.dir);
}

test "staged publication bounds name collisions without changing existing files" {
    const io = std.testing.io;
    const Hooks = struct {
        var attempts: usize = 0;
        fn random(_: ?*anyopaque, bytes: []u8) void {
            @memset(bytes, 0);
        }
        fn create(
            userdata: ?*anyopaque,
            directory: std.Io.Dir,
            name: []const u8,
            options: std.Io.Dir.CreateFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            attempts += 1;
            return std.testing.io.vtable.dirCreateFile(userdata, directory, name, options);
        }
    };
    Hooks.attempts = 0;
    var vtable = io.vtable.*;
    vtable.random = Hooks.random;
    vtable.dirCreateFile = Hooks.create;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const collision = "00000000000000000000000000000000";
    try tmp.dir.writeFile(io, .{ .sub_path = collision, .data = "preserved" });
    try std.testing.expectEqual(
        error.StagingNameExhausted,
        publishReplacement(
            injected,
            tmp.dir,
            tmp.dir,
            "entry",
            &.{"bytes"},
            .{},
        ).not_published.cause,
    );
    try std.testing.expectEqual(@as(usize, 16), Hooks.attempts);
    try expectContents(tmp.dir, collision, "preserved");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "entry", .{}));
}

test "a stage never aliases its destination when both handles name the same directory" {
    const io = std.testing.io;
    var vtable = io.vtable.*;
    vtable.random = struct {
        fn random(_: ?*anyopaque, bytes: []u8) void {
            @memset(bytes, 0xff);
        }
    }.random;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alias = try tmp.dir.openDir(io, ".", .{});
    defer alias.close(io);
    for ([_][]const u8{
        "ffffffffffffffffffffffffffffffff",
        "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
    }) |leaf| {
        try std.testing.expectEqual(
            error.StagingNameExhausted,
            publishReplacement(
                injected,
                tmp.dir,
                alias,
                leaf,
                &.{"bytes"},
                .{},
            ).not_published.cause,
        );
    }
    try expectEmpty(tmp.dir);
    try std.testing.expect(
        publishCreateNew(injected, tmp.dir, alias, "entry", &.{}, .{}) == .complete,
    );
    try expectContents(tmp.dir, "entry", "");
}

test "partial write failure removes the stage and preserves the old destination" {
    const io = std.testing.io;
    const Hooks = struct {
        var writes: usize = 0;
        fn operate(
            userdata: ?*anyopaque,
            operation: std.Io.Operation,
        ) std.Io.Cancelable!std.Io.Operation.Result {
            switch (operation) {
                .file_write_streaming => |write| {
                    writes += 1;
                    if (writes > 1) return .{ .file_write_streaming = error.NoSpaceLeft };
                    return std.testing.io.vtable.operate(userdata, .{ .file_write_streaming = .{
                        .file = write.file,
                        .data = &.{write.data[0][0..2]},
                    } });
                },
                else => return std.testing.io.vtable.operate(userdata, operation),
            }
        }
    };
    Hooks.writes = 0;
    var vtable = io.vtable.*;
    vtable.operate = Hooks.operate;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var staging = std.testing.tmpDir(.{ .iterate = true });
    defer staging.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    try destination.dir.writeFile(io, .{ .sub_path = "entry", .data = "old" });
    try std.testing.expectEqual(
        error.NoSpaceLeft,
        publishReplacement(
            injected,
            staging.dir,
            destination.dir,
            "entry",
            &.{"complete bytes"},
            .{},
        ).not_published.cause,
    );
    try std.testing.expectEqual(@as(usize, 2), Hooks.writes);
    try expectContents(destination.dir, "entry", "old");
    try expectEmpty(staging.dir);
}

test "file sync failure removes the stage while atomic visibility skips sync" {
    const io = std.testing.io;
    var vtable = io.vtable.*;
    vtable.fileSync = struct {
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }
    }.sync;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var staging = std.testing.tmpDir(.{ .iterate = true });
    defer staging.cleanup();
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    try std.testing.expectEqual(
        error.InputOutput,
        publishCreateNew(
            injected,
            staging.dir,
            destination.dir,
            "entry",
            &.{"bytes"},
            .{},
        ).not_published.cause,
    );
    try expectEmpty(staging.dir);
    try expectEmpty(destination.dir);
    try std.testing.expect(
        publishCreateNew(
            injected,
            staging.dir,
            destination.dir,
            "entry",
            &.{"bytes"},
            .{ .durability = .atomic_visibility },
        ) == .complete,
    );
    try expectContents(destination.dir, "entry", "bytes");
    try expectEmpty(staging.dir);
}

test "cancellation still attempts stage cleanup under cancellation protection" {
    const io = std.testing.io;
    const Hooks = struct {
        var protected = false;
        var protection: std.Io.CancelProtection = .unblocked;
        fn protect(_: ?*anyopaque, new: std.Io.CancelProtection) std.Io.CancelProtection {
            const previous = protection;
            protection = new;
            return previous;
        }
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.Canceled;
        }
        fn delete(
            userdata: ?*anyopaque,
            directory: std.Io.Dir,
            name: []const u8,
        ) std.Io.Dir.DeleteFileError!void {
            protected = protection == .blocked;
            return std.testing.io.vtable.dirDeleteFile(userdata, directory, name);
        }
    };
    Hooks.protected = false;
    Hooks.protection = .unblocked;
    var vtable = io.vtable.*;
    vtable.fileSync = Hooks.sync;
    vtable.dirDeleteFile = Hooks.delete;
    vtable.swapCancelProtection = Hooks.protect;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try std.testing.expectEqual(
        error.Canceled,
        publishCreateNew(injected, tmp.dir, tmp.dir, "entry", &.{"bytes"}, .{}).not_published.cause,
    );
    try std.testing.expect(Hooks.protected);
    try std.testing.expectEqual(.unblocked, Hooks.protection);
    try expectEmpty(tmp.dir);
}

test "rename failures never copy across devices and remove both operation stages" {
    const io = std.testing.io;
    var vtable = io.vtable.*;
    vtable.dirRename = struct {
        fn rename(
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: std.Io.Dir,
            _: []const u8,
        ) std.Io.Dir.RenameError!void {
            return error.AccessDenied;
        }
    }.rename;
    vtable.dirRenamePreserve = struct {
        fn rename(
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: std.Io.Dir,
            _: []const u8,
        ) std.Io.Dir.RenamePreserveError!void {
            return error.CrossDevice;
        }
    }.rename;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var staging = std.testing.tmpDir(.{ .iterate = true });
    defer staging.cleanup();
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    try std.testing.expectEqual(
        error.AccessDenied,
        publishReplacement(
            injected,
            staging.dir,
            destination.dir,
            "entry",
            &.{"bytes"},
            .{},
        ).publication_unknown.cause,
    );
    try std.testing.expectEqual(
        error.CrossDevice,
        publishCreateNew(
            injected,
            staging.dir,
            destination.dir,
            "entry",
            &.{"bytes"},
            .{},
        ).publication_unknown.cause,
    );
    try expectEmpty(staging.dir);
    try expectEmpty(destination.dir);
}

test "rename may report failure after publication without claiming unchanged destination" {
    const io = std.testing.io;
    var vtable = io.vtable.*;
    vtable.dirRename = struct {
        fn rename(
            userdata: ?*anyopaque,
            old_dir: std.Io.Dir,
            old_name: []const u8,
            new_dir: std.Io.Dir,
            new_name: []const u8,
        ) std.Io.Dir.RenameError!void {
            try std.testing.io.vtable.dirRename(userdata, old_dir, old_name, new_dir, new_name);
            return error.HardwareFailure;
        }
    }.rename;
    vtable.dirRenamePreserve = struct {
        fn rename(
            userdata: ?*anyopaque,
            old_dir: std.Io.Dir,
            old_name: []const u8,
            new_dir: std.Io.Dir,
            new_name: []const u8,
        ) std.Io.Dir.RenamePreserveError!void {
            try std.testing.io.vtable.dirRenamePreserve(
                userdata,
                old_dir,
                old_name,
                new_dir,
                new_name,
            );
            return error.HardwareFailure;
        }
    }.rename;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var staging = std.testing.tmpDir(.{ .iterate = true });
    defer staging.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    const immutable = publishCreateNew(
        injected,
        staging.dir,
        destination.dir,
        "entry",
        &.{"first complete bytes"},
        .{},
    ).publication_unknown;
    try std.testing.expectEqual(error.HardwareFailure, immutable.cause);
    try std.testing.expect(immutable.cleanup == null);
    try expectContents(destination.dir, "entry", "first complete bytes");
    const replacement = publishReplacement(
        injected,
        staging.dir,
        destination.dir,
        "entry",
        &.{"replacement complete bytes"},
        .{},
    ).publication_unknown;
    try std.testing.expectEqual(error.HardwareFailure, replacement.cause);
    try std.testing.expect(replacement.cleanup == null);
    try expectContents(destination.dir, "entry", "replacement complete bytes");
    try expectEmpty(staging.dir);
}

test "directory sync failures report published complete bytes for either directory" {
    const io = std.testing.io;
    const Hooks = struct {
        var sync_calls: usize = 0;
        var fail_at: usize = 0;
        fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            sync_calls += 1;
            if (sync_calls == fail_at) return error.InputOutput;
            return std.testing.io.vtable.fileSync(userdata, file);
        }
    };
    var vtable = io.vtable.*;
    vtable.fileSync = Hooks.sync;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var staging = std.testing.tmpDir(.{ .iterate = true });
    defer staging.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    for ([_]usize{ 2, 3 }) |fail_at| {
        Hooks.sync_calls = 0;
        Hooks.fail_at = fail_at;
        const result = publishReplacement(
            injected,
            staging.dir,
            destination.dir,
            "entry",
            &.{ "complete", " bytes" },
            .{ .durability = .file_and_directories_synced },
        );
        try std.testing.expectEqual(error.InputOutput, result.published_unsynced);
        try std.testing.expectEqual(fail_at, Hooks.sync_calls);
        try expectContents(destination.dir, "entry", "complete bytes");
        try expectEmpty(staging.dir);
    }
    Hooks.sync_calls = 0;
    Hooks.fail_at = 0;
    try std.testing.expect(
        publishReplacement(
            injected,
            staging.dir,
            destination.dir,
            "entry",
            &.{"durable"},
            .{ .durability = .file_and_directories_synced },
        ) == .complete,
    );
    try std.testing.expectEqual(@as(usize, 3), Hooks.sync_calls);
}

test "retained staging and destination handles survive parent replacement" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "selected/staging");
    try tmp.dir.createDirPath(io, "selected/destination");
    const staging = try tmp.dir.openDir(
        io,
        "selected/staging",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer staging.close(io);
    const destination = try tmp.dir.openDir(
        io,
        "selected/destination",
        .{ .follow_symlinks = false },
    );
    defer destination.close(io);
    try tmp.dir.rename("selected", tmp.dir, "retained", io);
    try tmp.dir.createDirPath(io, "selected/staging");
    try tmp.dir.createDirPath(io, "selected/destination");
    try std.testing.expect(
        publishCreateNew(
            io,
            staging,
            destination,
            "entry",
            &.{"retained"},
            .{ .durability = .file_and_directories_synced },
        ) == .complete,
    );
    try expectContents(tmp.dir, "retained/destination/entry", "retained");
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io, "selected/destination/entry", .{}),
    );
    try expectEmpty(staging);
}

test "cleanup failure reports retained stage without publishing destination" {
    const io = std.testing.io;
    const Hooks = struct {
        var cleanup_attempted = false;
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }
        fn delete(_: ?*anyopaque, _: std.Io.Dir, _: []const u8) std.Io.Dir.DeleteFileError!void {
            cleanup_attempted = true;
            return error.AccessDenied;
        }
    };
    Hooks.cleanup_attempted = false;
    var vtable = io.vtable.*;
    vtable.fileSync = Hooks.sync;
    vtable.dirDeleteFile = Hooks.delete;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var staging = std.testing.tmpDir(.{ .iterate = true });
    defer staging.cleanup();
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    const failure = publishCreateNew(
        injected,
        staging.dir,
        destination.dir,
        "entry",
        &.{"bytes"},
        .{},
    ).not_published;
    try std.testing.expectEqual(error.InputOutput, failure.cause);
    try std.testing.expectEqual(error.AccessDenied, failure.cleanup.?.cause);
    try std.testing.expect(Hooks.cleanup_attempted);
    try expectEmpty(destination.dir);
    var entries = staging.dir.iterate();
    const stage = (try entries.next(io)).?;
    try std.testing.expectEqualStrings(stage.name, &failure.cleanup.?.stage_name);
    try expectContents(staging.dir, stage.name, "bytes");
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try entries.next(io));
}
