const std = @import("std");
const ledger_main = @import("main.zig");

pub const panic = ledger_main.panic;
pub const std_options = ledger_main.std_options;

const Fault = enum {
    none,
    publication,
    capture,
    verification,
    cleanup,
    partial_cleanup,
    finalization,
};
var original: *const std.Io.VTable = undefined;
var fault: Fault = .none;
var triggered: std.atomic.Value(bool) = .init(false);
var committed: std.atomic.Value(bool) = .init(false);
const no_handle = std.math.maxInt(usize);
var payload_handle: std.atomic.Value(usize) = .init(no_handle);
var marker_handle: std.atomic.Value(usize) = .init(no_handle);
var payload_deletions: usize = 0;

var measurement_io: std.Io = undefined;
var measurement_allocator: std.mem.Allocator = undefined;
var measurement_path: ?[]const u8 = null;
var measurement_root: std.Io.Dir = undefined;
var measurement_root_path: [:0]const u8 = undefined;
var measurements: Measurements = .{};

const Sizes = struct {
    preparation_bytes: u64 = 0,
    native_working_bytes: u64 = 0,
    native_audit_bytes: u64 = 0,
    canonical_bytes: u64 = 0,

    fn working(self: Sizes) u64 {
        return self.preparation_bytes + self.native_working_bytes;
    }
};

const Measurements = struct {
    schema: []const u8 = "ledger-preparation-probe-measurements/v1",
    method: []const u8 = "successful-io-counts-and-synchronous-fixture-metadata",
    limitations: []const u8 = "quiescent disposable target; logical lengths; " ++
        "reads include invocation inputs; excludes observer and stdout/stderr IO; " ++
        "physical blocks unknown",
    bytes_read: u64 = 0,
    target_bytes_written: u64 = 0,
    positional_bytes_written: u64 = 0,
    streaming_bytes_written: u64 = 0,
    reclaimed_payload_bytes: u64 = 0,
    initial: Sizes = .{},
    retained: Sizes = .{},
    peak_working_bytes: u64 = 0,
    peak_native_working_bytes: u64 = 0,
    peak_additional_working_bytes: u64 = 0,
    samples: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    var observed_directory: ?std.Io.Dir = null;
    defer if (observed_directory) |directory| directory.close(init.io);
    var observed_path: ?[:0]const u8 = null;
    defer if (observed_path) |path| init.gpa.free(path);
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len > 1 and (std.mem.eql(u8, argv[1], "prepare") or
        std.mem.eql(u8, argv[1], "maintain")))
    {
        if (init.environ_map.get("LEDGER_PREPARATION_FAULT")) |name| {
            fault = std.meta.stringToEnum(Fault, name) orelse
                return error.InvalidPreparationProbeFault;
        }
    }
    original = init.io.vtable;
    measurement_io = init.io;
    measurement_allocator = init.gpa;
    if (init.environ_map.get("LEDGER_PREPARATION_MEASURE")) |path| {
        var root_path: ?[]const u8 = null;
        for (argv[0 .. argv.len - 1], 0..) |arg, index| {
            if (std.mem.eql(u8, arg, "--store-root")) root_path = argv[index + 1];
        }
        const root = try std.Io.Dir.openDirAbsolute(init.io, root_path orelse
            return error.PreparationProbeMissingRoot, .{});
        defer root.close(init.io);
        measurement_root = try root.openDir(init.io, ".ledger", .{ .iterate = true });
        observed_directory = measurement_root;
        measurement_root_path = try measurement_root.realPathFileAlloc(init.io, ".", init.gpa);
        observed_path = measurement_root_path;
        if (std.mem.startsWith(u8, path, measurement_root_path)) {
            return error.PreparationProbeReportInsideTarget;
        }
        measurement_path = path;
        sample();
        measurements.initial = measurements.retained;
        measurements.peak_additional_working_bytes = 0;
    }
    var vtable = original.*;
    vtable.dirRename = rename;
    vtable.dirCreateFile = createFile;
    vtable.dirOpenFile = openFile;
    vtable.dirDeleteFile = deleteFile;
    vtable.fileWritePositional = writePositional;
    vtable.fileReadPositional = readPositional;
    vtable.fileSync = syncFile;
    vtable.fileClose = closeFiles;
    vtable.operate = operate;
    vtable.dirCreateFileAtomic = createFileAtomic;
    vtable.dirRenamePreserve = renamePreserve;
    vtable.fileSetLength = setLength;
    var wrapped = init;
    wrapped.io.vtable = &vtable;
    try ledger_main.main(wrapped);
    report();
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
    sample();
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
    if (failFinalization(header, data)) return error.NoSpaceLeft;
    const count = try original.fileWritePositional(userdata, file, header, data, splat, offset);
    observeWrite(file, count, false);
    if (fault == .capture and count != 0 and
        payload_handle.load(.monotonic) == @as(usize, @intCast(file.handle)))
    {
        triggered.store(true, .monotonic);
        report();
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
    const count = try original.fileReadPositional(userdata, file, data, offset);
    observeRead(file, count);
    return count;
}

fn deleteFile(
    userdata: ?*anyopaque,
    directory: std.Io.Dir,
    path: []const u8,
) std.Io.Dir.DeleteFileError!void {
    const payload = std.mem.startsWith(u8, std.fs.path.basename(path), "payload-");
    if ((fault == .cleanup or (fault == .partial_cleanup and payload_deletions == 1)) and
        payload and
        !triggered.swap(true, .monotonic)) return error.AccessDenied;
    const payload_bytes = if (measurement_path != null and payload)
        (directory.statFile(measurement_io, path, .{ .follow_symlinks = false }) catch
            @panic("probe cannot stat deleted payload")).size
    else
        0;
    try original.dirDeleteFile(userdata, directory, path);
    if (payload) payload_deletions += 1;
    measurements.reclaimed_payload_bytes += payload_bytes;
    sample();
}

fn rename(
    userdata: ?*anyopaque,
    old_dir: std.Io.Dir,
    old_sub_path: []const u8,
    new_dir: std.Io.Dir,
    new_sub_path: []const u8,
) std.Io.Dir.RenameError!void {
    try original.dirRename(userdata, old_dir, old_sub_path, new_dir, new_sub_path);
    sample();
    if (fault == .publication and
        std.mem.startsWith(u8, old_sub_path, ".ledger-dtx-stage-") and
        std.mem.eql(u8, new_sub_path, "operation.json"))
    {
        triggered.store(true, .monotonic);
        report();
        std.process.exit(99);
    }
}

fn observeRead(file: std.Io.File, count: usize) void {
    if (measurement_path == null or file.handle <= 2) return;
    measurements.bytes_read += count;
}

fn observeWrite(file: std.Io.File, count: usize, streaming: bool) void {
    if (measurement_path == null) return;
    if (file.handle <= 2) {
        report();
        return;
    }
    var path_buffer: [4096]u8 = undefined;
    const length = original.fileRealPath(measurement_io.userdata, file, &path_buffer) catch
        @panic("probe cannot identify written file");
    const path = path_buffer[0..length];
    if (std.mem.startsWith(u8, path, measurement_root_path) and
        path.len > measurement_root_path.len and path[measurement_root_path.len] == '/')
    {
        measurements.target_bytes_written += count;
        if (streaming) {
            measurements.streaming_bytes_written += count;
        } else {
            measurements.positional_bytes_written += count;
        }
    } else @panic("probe observed a write outside its disposable target");
    sample();
}

fn operate(
    userdata: ?*anyopaque,
    operation: std.Io.Operation,
) std.Io.Cancelable!std.Io.Operation.Result {
    if (operation == .file_write_streaming) {
        const write = operation.file_write_streaming;
        if (failFinalization(write.header, write.data)) {
            return .{ .file_write_streaming = error.NoSpaceLeft };
        }
    }
    const result = try original.operate(userdata, operation);
    switch (operation) {
        .file_write_streaming => |write| if (result.file_write_streaming) |count| {
            observeWrite(write.file, count, true);
        } else |_| {},
        .file_read_streaming => |read| if (result.file_read_streaming) |count| {
            observeRead(read.file, count);
        } else |_| {},
        else => {},
    }
    return result;
}

fn failFinalization(header: []const u8, data: []const []const u8) bool {
    if (fault != .finalization or payload_deletions == 0) return false;
    const needle = "\"phase\":\"finalized\"";
    var finalizing = std.mem.indexOf(u8, header, needle) != null;
    for (data) |part| finalizing = finalizing or std.mem.indexOf(u8, part, needle) != null;
    return finalizing and !triggered.swap(true, .monotonic);
}

fn createFileAtomic(
    userdata: ?*anyopaque,
    directory: std.Io.Dir,
    path: []const u8,
    options: std.Io.Dir.CreateFileAtomicOptions,
) std.Io.Dir.CreateFileAtomicError!std.Io.File.Atomic {
    const file = try original.dirCreateFileAtomic(userdata, directory, path, options);
    if (measurement_path != null and !file.file_exists) @panic("unmeasured unnamed atomic file");
    sample();
    return file;
}

fn renamePreserve(
    userdata: ?*anyopaque,
    old_dir: std.Io.Dir,
    old_path: []const u8,
    new_dir: std.Io.Dir,
    new_path: []const u8,
) std.Io.Dir.RenamePreserveError!void {
    try original.dirRenamePreserve(userdata, old_dir, old_path, new_dir, new_path);
    sample();
}

fn setLength(
    userdata: ?*anyopaque,
    file: std.Io.File,
    length: u64,
) std.Io.File.SetLengthError!void {
    try original.fileSetLength(userdata, file, length);
    sample();
}

fn sample() void {
    if (measurement_path == null) return;
    var sizes: Sizes = .{};
    inspectDirectory(&sizes) catch |err|
        std.debug.panic("preparation probe measurement failed: {s}", .{@errorName(err)});
    measurements.retained = sizes;
    measurements.peak_working_bytes = @max(measurements.peak_working_bytes, sizes.working());
    measurements.peak_native_working_bytes = @max(
        measurements.peak_native_working_bytes,
        sizes.native_working_bytes,
    );
    measurements.peak_additional_working_bytes = measurements.peak_working_bytes -|
        measurements.initial.working();
    measurements.samples += 1;
}

const DirectoryFrame = struct {
    directory: std.Io.Dir,
    iterator: std.Io.Dir.Iterator,
    path: []const u8,
};

fn inspectDirectory(sizes: *Sizes) !void {
    var stack: [17]DirectoryFrame = undefined;
    stack[0] = .{
        .directory = measurement_root,
        .iterator = measurement_root.iterate(),
        .path = "",
    };
    var depth: usize = 1;
    defer while (depth > 1) {
        depth -= 1;
        stack[depth].directory.close(measurement_io);
        measurement_allocator.free(stack[depth].path);
    };
    var entries: usize = 0;
    while (depth > 0) {
        const frame = &stack[depth - 1];
        const entry = try frame.iterator.next(measurement_io) orelse {
            depth -= 1;
            if (depth > 0) {
                frame.directory.close(measurement_io);
                measurement_allocator.free(frame.path);
            }
            continue;
        };
        entries += 1;
        if (entries > 4096) return error.ProbeEntryBoundExceeded;
        const path = try std.fs.path.join(measurement_allocator, &.{ frame.path, entry.name });
        var path_transferred = false;
        defer if (!path_transferred) measurement_allocator.free(path);
        const stat = try frame.directory.statFile(
            measurement_io,
            entry.name,
            .{ .follow_symlinks = false },
        );
        if (stat.kind == .directory) {
            if (depth == stack.len) return error.ProbeDepthExceeded;
            const child = try frame.directory.openDir(
                measurement_io,
                entry.name,
                .{ .iterate = true, .follow_symlinks = false },
            );
            stack[depth] = .{ .directory = child, .iterator = child.iterate(), .path = path };
            depth += 1;
            path_transferred = true;
        } else if (stat.kind == .file) {
            try addFileSize(path, entry.name, stat.size, sizes);
        } else return error.ProbeSpecialFile;
    }
}

fn addFileSize(path: []const u8, name: []const u8, size: u64, sizes: *Sizes) !void {
    const lock = std.mem.endsWith(u8, name, ".lock") or
        std.mem.endsWith(u8, name, ".lock.advisory");
    if (lock or std.mem.eql(u8, path, ".fencing.counter")) {
        sizes.native_audit_bytes += size;
    } else if (std.mem.startsWith(u8, path, ".preparation/")) {
        sizes.preparation_bytes += size;
    } else if (std.mem.startsWith(u8, name, ".ledger-dtx-stage-") or isAtomicName(name)) {
        sizes.native_working_bytes += size;
    } else if (std.mem.startsWith(u8, path, ".transactions/")) {
        sizes.native_audit_bytes += size;
    } else if (std.mem.startsWith(u8, path, ".bindings/") or
        std.mem.startsWith(u8, path, ".definitions/") or
        std.mem.startsWith(u8, path, ".revisions/") or
        std.mem.eql(u8, path, "example/events.jsonl"))
    {
        sizes.canonical_bytes += size;
    } else return error.ProbeUnknownFile;
}

fn isAtomicName(name: []const u8) bool {
    if (name.len != 16 and name.len != 32) return false;
    for (name) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn report() void {
    const path = measurement_path orelse return;
    sample();
    const bytes = std.json.Stringify.valueAlloc(measurement_allocator, measurements, .{}) catch
        @panic("probe cannot encode measurement");
    defer measurement_allocator.free(bytes);
    std.Io.Dir.cwd().writeFile(measurement_io, .{ .sub_path = path, .data = bytes }) catch
        @panic("probe cannot write measurement");
}
