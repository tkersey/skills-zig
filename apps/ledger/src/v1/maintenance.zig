const std = @import("std");
const storage_root = @import("storage_root");
const preparation = @import("preparation.zig");
const work = @import("preparation_work.zig");
const space = @import("preparation_space.zig");

pub const Measurements = struct {
    scope: []const u8 = "managed-control-top-level",
    method: []const u8 = "bounded-metadata-inspection",
    coverage: []const u8 = "top-level-only",
    observed_entries: usize = 0,
    observed_regular_bytes: u64 = 0,
    directories_with_unknown_size: usize = 0,
    foreign_entry_count: usize = 0,
    required_history_bytes: ?u64 = null,
    retained_legacy_bytes: ?u64 = null,
    physical_bytes_freed: ?u64 = null,
};

pub const Result = struct {
    schema: []const u8 = "ledger-maintenance-result/v1",
    store_root: ?[]const u8 = null,
    store_id: ?[]const u8 = null,
    outcome: []const u8 = "healthy",
    phase: []const u8 = "inspection",
    storage_mutated: ?bool = false,
    authority_granted: bool = false,
    error_code: ?[]const u8 = null,
    preparation: ?work.Report = null,
    limits: preparation.Limits,
    bytes_read: usize = 0,
    file_reads: usize = 0,
    free_bytes: ?u64,
    measurements: Measurements = .{},
};

pub fn execute(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    limits: preparation.Limits,
    apply: bool,
) !Result {
    if (!storage_root.isActive(scope)) return error.MaintenanceRequiresManagedTarget;
    try limits.validate();
    var budget: storage_root.ReadBudget = .{
        .max_bytes = limits.max_read_bytes,
        .max_files = limits.max_files * 4,
    };
    const previous_budget = scope.read_budget;
    scope.read_budget = &budget;
    defer scope.read_budget = previous_budget;
    var result: Result = .{
        .limits = limits,
        .free_bytes = space.availableBytes(scope.fs.directory()),
    };
    inspectAndFinalize(scope, allocator, limits, apply, &result) catch |err| {
        result.outcome = switch (err) {
            error.PreparationFileBoundExceeded,
            error.PreparationSpaceBoundExceeded,
            error.PreparationReadBoundExceeded,
            error.TooManyFiles,
            error.FileTooBig,
            => "incomplete",
            error.LockBusy,
            error.EventStoreBusy,
            error.TransactionRecoveryRequired,
            error.PreparationOwnershipUnknown,
            => "blocked",
            else => "failure",
        };
        result.error_code = @errorName(err);
    };
    result.storage_mutated = scope.mutation_state;
    result.bytes_read = budget.bytes;
    result.file_reads = budget.files;
    return result;
}

fn inspectAndFinalize(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    limits: preparation.Limits,
    apply: bool,
    result: *Result,
) !void {
    result.preparation = try work.inspect(scope, allocator, limits);
    const observed = result.preparation.?;
    if (apply and observed.phase != .absent and observed.phase != .finalized) {
        var workspace = try work.Workspace.acquire(scope, allocator);
        defer workspace.deinit();
        result.phase = "cleanup";
        result.preparation = try workspace.reconcile(limits, true);
    }
    var directory = try scope.fs.directory().openDir(scope.fs.io, ".", .{ .iterate = true });
    defer directory.close(scope.fs.io);
    var iterator = directory.iterate();
    while (try iterator.next(scope.fs.io)) |entry| {
        if (result.measurements.observed_entries == limits.max_files) {
            result.measurements.coverage = "incomplete-top-level";
            return error.PreparationFileBoundExceeded;
        }
        result.measurements.observed_entries += 1;
        const stat = try directory.statFile(scope.fs.io, entry.name, .{ .follow_symlinks = false });
        switch (stat.kind) {
            .file => result.measurements.observed_regular_bytes = try std.math.add(
                u64,
                result.measurements.observed_regular_bytes,
                stat.size,
            ),
            .directory => result.measurements.directories_with_unknown_size += 1,
            else => result.measurements.foreign_entry_count += 1,
        }
    }
}

test "maintenance inspection is nonmutating and preserves unknown files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "foreign", .data = "retained" });
    var scope = storage_root.Scope.init(.anchored(std.testing.io, tmp.dir));
    const before = try tmp.dir.stat(std.testing.io);
    const inspected = try execute(&scope, allocator, .{}, false);
    try std.testing.expectEqualStrings("healthy", inspected.outcome);
    try std.testing.expectEqual(@as(?bool, false), inspected.storage_mutated);
    try std.testing.expectEqual(before.mtime, (try tmp.dir.stat(std.testing.io)).mtime);
    const applied = try execute(&scope, allocator, .{}, true);
    try std.testing.expectEqual(@as(?bool, false), applied.storage_mutated);
    const bytes = try scope.readFile(allocator, "foreign", 64);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("retained", bytes);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(
        std.testing.io,
        ".preparation",
        .{ .follow_symlinks = false },
    ));
}
