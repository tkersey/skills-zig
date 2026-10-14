const std = @import("std");

/// Open an owned traversal handle without requiring directory-listing permission.
/// The caller closes it with the same I/O. Substituted I/O retains its own policy.
pub fn openSearchDirectory(
    io: std.Io,
    parent: std.Io.Dir,
    path: []const u8,
    options: struct { follow_symlinks: bool = true },
) !std.Io.Dir {
    try io.checkCancel();
    return parent.openDir(io, path, .{ .follow_symlinks = options.follow_symlinks }) catch |err| {
        if (@import("builtin").os.tag != .macos) return err;
        if (err != error.AccessDenied) return err;
        // Read only the static vtable, never the undefined backend instance. A
        // substituted opener keeps its own admission/failure policy and handles.
        const native_opener = comptime std.Io.Threaded.io(undefined).vtable.dirOpenDir;
        if (io.vtable.dirOpenDir != native_opener) return err;
        return openDarwinSearchDirectory(io, parent, path, options.follow_symlinks);
    };
}

// Keep the exceptional search-only path and its path buffer out of ordinary
// directory admission, including its caller's resident code and stack pages.
noinline fn openDarwinSearchDirectory(
    io: std.Io,
    parent: std.Io.Dir,
    path: []const u8,
    follow_symlinks: bool,
) !std.Io.Dir {
    // Zig's Darwin directory opener requires read permission even when iteration
    // is not requested. O_SEARCH (available on our macOS 15 minimum) supplies
    // precisely the traversal capability used here. There is no alternate I/O
    // backend: cancellation uses the caller's I/O, and openat uses its parent.
    // Remove this bridge when std.Io exposes search-only directory admission.
    if (path.len >= std.posix.PATH_MAX) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPathName;
    var buffer: [std.posix.PATH_MAX]u8 = undefined;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const base_flags: std.c.O = .{
        .DIRECTORY = true,
        .NOFOLLOW = !follow_symlinks,
        .CLOEXEC = true,
    };
    const flags: std.c.O = @bitCast(@as(u32, @bitCast(base_flags)) | 0x40000000);
    // Interrupted syscalls retry until cancellation or a result.
    while (true) { // tiger: event-loop
        try io.checkCancel();
        const result = std.c.openat(parent.handle, buffer[0..path.len :0], flags);
        switch (std.posix.errno(result)) {
            .SUCCESS => return .{ .handle = result },
            .INTR => continue,
            .INVAL, .ILSEQ => return error.BadPathName,
            .ACCES => return error.AccessDenied,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV, .NXIO => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

pub fn readStdinAlloc(io: std.Io, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var reader = std.Io.File.stdin().reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

pub fn readFileAlloc(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return dir.readFileAlloc(io, path, allocator, .limited(max_bytes));
}

pub fn realPathAlloc(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![:0]u8 {
    return dir.realPathFileAlloc(io, path, allocator);
}

pub fn isClosedPipeError(err: anyerror) bool {
    return err == error.BrokenPipe;
}

/// For terminal output only: callers that have subsequent effects must propagate
/// BrokenPipe themselves so a closed reader stops those effects.
pub fn writeToStreamAllowBrokenPipe(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    file.writeStreamingAll(io, bytes) catch |err| switch (err) {
        error.BrokenPipe => return,
        else => return err,
    };
}

pub fn writeAllAllowBrokenPipe(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    return writeToStreamAllowBrokenPipe(io, file, bytes);
}

test "search directory handles preserve traversal without listing permission" {
    if (@import("builtin").os.tag != .macos and
        @import("builtin").os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "restricted", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "restricted/known", .data = "present" });
    try tmp.dir.symLink(io, "restricted", "alias", .{ .is_directory = true });
    try tmp.dir.setFilePermissions(io, "restricted", .fromMode(0o100), .{});
    defer tmp.dir.setFilePermissions(io, "restricted", .fromMode(0o700), .{}) catch |err| {
        std.debug.panic("restore search-directory test permissions: {s}", .{@errorName(err)});
    };
    var directory = try openSearchDirectory(io, tmp.dir, "restricted", .{});
    defer directory.close(io);
    const bytes = try directory.readFileAlloc(io, "known", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("present", bytes);
    var alias = try openSearchDirectory(io, tmp.dir, "alias", .{});
    defer alias.close(io);
    try std.testing.expectEqual((try directory.stat(io)).inode, (try alias.stat(io)).inode);
    if (openSearchDirectory(io, tmp.dir, "alias", .{ .follow_symlinks = false })) |unexpected| {
        unexpected.close(io);
        return error.AcceptedSymlink;
    } else |err| switch (err) {
        error.NotDir, error.SymLinkLoop => {},
        else => return err,
    }
    // A child can use the owned search handle directly, without a path relookup.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "test -f known" },
        .cwd = .{ .dir = directory },
    });
    defer child.kill(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

test "search directory admission preserves substituted I/O errors" {
    const Denied = struct {
        fn open(
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: std.Io.Dir.OpenOptions,
        ) std.Io.Dir.OpenError!std.Io.Dir {
            return error.AccessDenied;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.dirOpenDir = Denied.open;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.AccessDenied, openSearchDirectory(io, .cwd(), ".", .{}));
}

test "only a proven broken pipe is a closed reader" {
    try std.testing.expect(isClosedPipeError(error.BrokenPipe));
    try std.testing.expect(!isClosedPipeError(error.WriteFailed));
    try std.testing.expect(!isClosedPipeError(error.AccessDenied));
}

test "filesystem helpers retain the supplied directory authority" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    try first.dir.writeFile(io, .{ .sub_path = "same", .data = "first" });
    try second.dir.writeFile(io, .{ .sub_path = "same", .data = "second" });
    const first_bytes = try readFileAlloc(io, first.dir, allocator, "same", 32);
    defer allocator.free(first_bytes);
    const second_bytes = try readFileAlloc(io, second.dir, allocator, "same", 32);
    defer allocator.free(second_bytes);
    try std.testing.expectEqualStrings("first", first_bytes);
    try std.testing.expectEqualStrings("second", second_bytes);
    const first_path = try realPathAlloc(io, first.dir, allocator, "same");
    defer allocator.free(first_path);
    const second_path = try realPathAlloc(io, second.dir, allocator, "same");
    defer allocator.free(second_path);
    try std.testing.expect(!std.mem.eql(u8, first_path, second_path));
}

test "filesystem helpers propagate supplied I/O cancellation" {
    const Canceled = struct {
        fn open(
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: std.Io.Dir.OpenFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            return error.Canceled;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.dirOpenFile = Canceled.open;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(
        error.Canceled,
        readFileAlloc(io, std.Io.Dir.cwd(), std.testing.allocator, "unused", 32),
    );
}

test "terminal writes use supplied I/O and swallow only broken pipe" {
    const ClosedReader = struct {
        fn operate(_: ?*anyopaque, op: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            return switch (op) {
                .file_write_streaming => .{ .file_write_streaming = error.BrokenPipe },
                else => unreachable,
            };
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.operate = ClosedReader.operate;
    const io: std.Io = .{ .userdata = null, .vtable = &vtable };
    try writeToStreamAllowBrokenPipe(io, std.Io.File.stdout(), "closed");
    try writeAllAllowBrokenPipe(io, std.Io.File.stdout(), "closed");
    try std.testing.expectError(
        error.InputOutput,
        writeToStreamAllowBrokenPipe(std.Io.failing, std.Io.File.stdout(), "failed"),
    );
    try std.testing.expectError(
        error.InputOutput,
        writeAllAllowBrokenPipe(std.Io.failing, std.Io.File.stdout(), "failed"),
    );
}
