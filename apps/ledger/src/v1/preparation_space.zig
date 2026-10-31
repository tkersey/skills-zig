const std = @import("std");
const builtin = @import("builtin");

const DarwinStatFs = extern struct {
    block_size: u32,
    io_size: i32,
    blocks: u64,
    free_blocks: u64,
    available_blocks: u64,
    files: u64,
    free_files: u64,
    fsid: [2]i32,
    owner: u32,
    kind: u32,
    flags: u32,
    subtype: u32,
    type_name: [16]u8,
    mount_path: [1024]u8,
    source_path: [1024]u8,
    extended_flags: u32,
    reserved: [7]u32,
};

const LinuxStatFs = extern struct {
    kind: usize,
    block_size: usize,
    blocks: u64,
    free_blocks: u64,
    available_blocks: u64,
    files: u64,
    free_files: u64,
    fsid: [2]i32,
    name_length: usize,
    fragment_size: usize,
    flags: usize,
    spare: [4]usize,
};

extern "c" fn fstatfs(fd: c_int, output: *DarwinStatFs) c_int;
extern "c" fn @"fstatfs$INODE64"(fd: c_int, output: *DarwinStatFs) c_int;

pub fn availableBytes(directory: std.Io.Dir) ?u64 {
    if (builtin.os.tag == .macos) {
        var output: DarwinStatFs = undefined;
        const status = if (builtin.cpu.arch == .x86_64)
            @"fstatfs$INODE64"(directory.handle, &output)
        else
            fstatfs(directory.handle, &output);
        if (status != 0) return null;
        return std.math.mul(u64, output.available_blocks, output.block_size) catch null;
    }
    if (builtin.os.tag == .linux and
        (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64))
    {
        var output: LinuxStatFs = undefined;
        const status = std.os.linux.syscall2(
            .fstatfs,
            @intCast(directory.handle),
            @intFromPtr(&output),
        );
        if (std.os.linux.errno(status) != .SUCCESS) return null;
        return std.math.mul(u64, output.available_blocks, output.block_size) catch null;
    }
    return null;
}

pub fn peakAdditionalBytes(selected_bytes: usize) !usize {
    const bulk = try std.math.mul(usize, selected_bytes, 3);
    return std.math.add(usize, bulk, 4 * 1024 * 1024);
}

test "preparation space reads the admitted filesystem and bounds peak estimate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    if (builtin.os.tag == .macos or
        (builtin.os.tag == .linux and
            (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64)))
    {
        try std.testing.expect(availableBytes(tmp.dir) != null);
    }
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024 + 300), try peakAdditionalBytes(100));
    try std.testing.expectError(error.Overflow, peakAdditionalBytes(std.math.maxInt(usize)));
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 120), @sizeOf(LinuxStatFs));
    try std.testing.expectEqual(@as(usize, 2168), @sizeOf(DarwinStatFs));
}
