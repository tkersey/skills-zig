pub const DefinitionIdentity = struct {
    id: []const u8,
    digest: []const u8,
    abi: []const u8,
};

pub const CompileStats = struct {
    cache_hit: bool = false,
    cache_write_failed: bool = false,
    compile_ns: u64 = 0,
    closure_files: usize = 0,
    closure_bytes: usize = 0,
};

pub const ExecutionStats = struct {
    execution_ns: u64 = 0,
    physical_passes: usize = 0,
    files_opened: usize = 0,
    bytes_read: usize = 0,
    rows_scanned: usize = 0,
    rows_materialized: usize = 0,
    output_rows: usize = 0,
    output_bytes: usize = 0,
};

pub const AuthorityBoundary = struct {
    authority_granted: bool = false,
    storage_mutated: bool = false,
};

test "common result metadata cannot default to authority" {
    const boundary: AuthorityBoundary = .{};
    try @import("std").testing.expect(!boundary.authority_granted);
    try @import("std").testing.expect(!boundary.storage_mutated);
}
