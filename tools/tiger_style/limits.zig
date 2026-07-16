const std = @import("std");

pub const diagnostics_max: u32 = 256;
pub const diff_bytes_max: usize = 32 * 1024 * 1024;
pub const file_bytes_max: usize = 16 * 1024 * 1024;
pub const files_max: u32 = 4096;
pub const function_lines_max: u32 = 70;
pub const line_columns_max: u32 = 100;
pub const revision_bytes_max: u32 = 256;
pub const lines_per_file_max: u32 = 1_000_000;

comptime {
    std.debug.assert(function_lines_max == 70);
    std.debug.assert(line_columns_max == 100);
    std.debug.assert(diff_bytes_max >= file_bytes_max);
    std.debug.assert(file_bytes_max < std.math.maxInt(i32));
    std.debug.assert(diagnostics_max < lines_per_file_max);
}
