const std = @import("std");
const ledger_main = @import("main.zig");

pub const panic = ledger_main.panic;
pub const std_options = ledger_main.std_options;

const Fault = enum { none, publication, capture, verification, cleanup };
var original: *const std.Io.VTable = undefined;
var fault: Fault = .none;
var triggered: std.atomic.Value(bool) = .init(false);
var committed: std.atomic.Value(bool) = .init(false);
const no_handle = std.math.maxInt(usize);
var payload_handle: std.atomic.Value(usize) = .init(no_handle);
var marker_handle: std.atomic.Value(usize) = .init(no_handle);

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "prepare")) {
        if (init.environ_map.get("LEDGER_PREPARATION_FAULT")) |name| {
            fault = std.meta.stringToEnum(Fault, name) orelse
                return error.InvalidPreparationProbeFault;
        }
    }
    original = init.io.vtable;
    var vtable = original.*;
    vtable.dirRename = rename;
    vtable.dirCreateFile = createFile;
    vtable.dirOpenFile = openFile;
    vtable.dirDeleteFile = deleteFile;
    vtable.fileWritePositional = writePositional;
    vtable.fileReadPositional = readPositional;
    vtable.fileSync = syncFile;
    vtable.fileClose = closeFiles;
    var wrapped = init;
    wrapped.io.vtable = &vtable;
    try ledger_main.main(wrapped);
    if (fault != .none and !triggered.load(.monotonic)) {
        return error.PreparationProbeFaultNotReached;
    }
}

fn createFile(
    userdata: ?*anyopaque,
    directory: std.Io.Dir,
    path: []const u8,
    options: std.Io.Dir.CreateFileOptions,
) std.Io.File.OpenError!std.Io.File {
    const file = try original.dirCreateFile(userdata, directory, path, options);
    if (std.mem.eql(u8, std.fs.path.basename(path), "commit.json")) {
        marker_handle.store(@intCast(file.handle), .monotonic);
    }
    return file;
}

fn openFile(
    userdata: ?*anyopaque,
    directory: std.Io.Dir,
    path: []const u8,
    options: std.Io.Dir.OpenFileOptions,
) std.Io.File.OpenError!std.Io.File {
    const file = try original.dirOpenFile(userdata, directory, path, options);
    if (fault == .capture and options.mode == .read_write and
        std.mem.startsWith(u8, std.fs.path.basename(path), "payload-"))
    {
        payload_handle.store(@intCast(file.handle), .monotonic);
    }
    return file;
}

fn writePositional(
    userdata: ?*anyopaque,
    file: std.Io.File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) std.Io.File.WritePositionalError!usize {
    const count = try original.fileWritePositional(userdata, file, header, data, splat, offset);
    if (fault == .capture and count != 0 and
        payload_handle.load(.monotonic) == @as(usize, @intCast(file.handle)))
    {
        triggered.store(true, .monotonic);
        std.process.exit(99);
    }
    return count;
}

fn syncFile(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
    try original.fileSync(userdata, file);
    if (marker_handle.load(.monotonic) == @as(usize, @intCast(file.handle))) {
        committed.store(true, .monotonic);
    }
}

fn closeFiles(userdata: ?*anyopaque, files: []const std.Io.File) void {
    for (files) |file| {
        const handle: usize = @intCast(file.handle);
        if (payload_handle.load(.monotonic) == handle) payload_handle.store(no_handle, .monotonic);
        if (marker_handle.load(.monotonic) == handle) marker_handle.store(no_handle, .monotonic);
    }
    original.fileClose(userdata, files);
}

fn readPositional(
    userdata: ?*anyopaque,
    file: std.Io.File,
    data: []const []u8,
    offset: u64,
) std.Io.File.ReadPositionalError!usize {
    if (fault == .verification and committed.load(.monotonic) and
        !triggered.swap(true, .monotonic)) return error.InputOutput;
    return original.fileReadPositional(userdata, file, data, offset);
}

fn deleteFile(
    userdata: ?*anyopaque,
    directory: std.Io.Dir,
    path: []const u8,
) std.Io.Dir.DeleteFileError!void {
    if (fault == .cleanup and
        std.mem.startsWith(u8, std.fs.path.basename(path), "payload-") and
        !triggered.swap(true, .monotonic)) return error.AccessDenied;
    try original.dirDeleteFile(userdata, directory, path);
}

fn rename(
    userdata: ?*anyopaque,
    old_dir: std.Io.Dir,
    old_sub_path: []const u8,
    new_dir: std.Io.Dir,
    new_sub_path: []const u8,
) std.Io.Dir.RenameError!void {
    try original.dirRename(userdata, old_dir, old_sub_path, new_dir, new_sub_path);
    if (fault == .publication and
        std.mem.startsWith(u8, old_sub_path, ".ledger-dtx-stage-") and
        std.mem.eql(u8, new_sub_path, "operation.json"))
    {
        triggered.store(true, .monotonic);
        std.process.exit(99);
    }
}
