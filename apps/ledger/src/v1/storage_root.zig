const std = @import("std");
const durable_store = @import("durable_store");

pub const marker_name = ".ledger-root.json";
const marker_schema = "ledger-storage-root/v1";

pub const Selection = struct {
    argv: []const []const u8,
    root: ?[]u8 = null,

    pub fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
        if (self.root) |root| allocator.free(root);
        self.* = undefined;
    }
};

pub fn hasSelector(argv: []const []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--store-root") or
            std.mem.eql(u8, arg, "--store-id")) return true;
    }
    return false;
}

/// Adapt an explicit managed root to the existing bounded custody engine. This
/// layer has no repository discovery or storage policy, and performs no writes.
pub fn prepare(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !Selection {
    if (!hasSelector(argv)) return .{ .argv = try allocator.dupe([]const u8, argv) };
    if (argv.len < 2 or !isDurableCommand(argv[1])) {
        return error.StorageRootRequiresDurableCommand;
    }
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    var root_arg: ?[]const u8 = null;
    var expected_id: ?[]const u8 = null;
    var root_index: ?usize = null;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--repo")) return error.ConflictingStorageRoots;
        if (std.mem.eql(u8, arg, "--store-root")) {
            if (root_arg != null) return error.DuplicateStorageRoot;
            index += 1;
            if (index == argv.len) return error.MissingStorageRoot;
            root_arg = argv[index];
            try args.append(allocator, "--repo");
            root_index = args.items.len;
            try args.append(allocator, argv[index]);
        } else if (std.mem.eql(u8, arg, "--store-id")) {
            if (expected_id != null) return error.DuplicateStoreIdentity;
            index += 1;
            if (index == argv.len) return error.MissingStoreIdentity;
            expected_id = argv[index];
        } else {
            try args.append(allocator, arg);
            // Do not reinterpret native option values as managed selectors.
            if (takesValue(arg)) {
                index += 1;
                if (index == argv.len) return error.MissingOptionValue;
                try args.append(allocator, argv[index]);
            }
        }
    }
    const root = try checkedRoot(
        allocator,
        io,
        root_arg orelse return error.MissingStorageRoot,
        expected_id orelse return error.MissingStoreIdentity,
    );
    errdefer allocator.free(root);
    args.items[root_index.?] = root;
    return .{ .argv = try args.toOwnedSlice(allocator), .root = root };
}

fn isDurableCommand(command: []const u8) bool {
    for ([_][]const u8{
        "transact",
        "project",
        "doctor",
        "migrate-segmented",
        "recovery",
    }) |name| {
        if (std.mem.eql(u8, command, name)) return true;
    }
    return false;
}

fn takesValue(arg: []const u8) bool {
    for ([_][]const u8{
        "--definition",
        "--operation",
        "--projection",
        "--input",
        "--param",
        "--format",
        "--transaction",
        "--resource",
        "--lock-id",
        "--fencing-token",
    }) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn checkedRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    supplied_root: []const u8,
    expected_id: []const u8,
) ![]u8 {
    if (!std.fs.path.isAbsolute(supplied_root)) return error.StorageRootNotAbsolute;
    if (expected_id.len == 0 or expected_id.len > 256) return error.InvalidStoreIdentity;
    try durable_store.rejectSymlinkComponents(supplied_root);
    const root = std.Io.Dir.cwd().realPathFileAlloc(
        io,
        supplied_root,
        allocator,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.StorageRootMissing,
        else => return err,
    };
    errdefer allocator.free(root);
    try checkMarker(allocator, io, root, expected_id);
    const control_path = try std.fs.path.join(allocator, &.{ root, ".ledger" });
    defer allocator.free(control_path);
    try durable_store.rejectSymlinkComponents(control_path);
    const stat = std.Io.Dir.cwd().statFile(
        io,
        control_path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return error.StorageRootMissing,
        else => return err,
    };
    if (stat.kind != .directory) return error.StorageRootNotDirectory;
    return root;
}

fn checkMarker(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    expected_id: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ root, marker_name });
    defer allocator.free(path);
    try durable_store.rejectSymlinkComponents(path);
    const stat = std.Io.Dir.cwd().statFile(
        io,
        path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return error.StorageRootUnregistered,
        else => return err,
    };
    if (stat.kind != .file or stat.size > 4096) return error.InvalidStorageRootMarker;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
    defer allocator.free(bytes);
    const Marker = struct { schema: []const u8, store_id: []const u8 };
    var marker = std.json.parseFromSlice(Marker, allocator, bytes, .{}) catch
        return error.InvalidStorageRootMarker;
    defer marker.deinit();
    if (!std.mem.eql(u8, marker.value.schema, marker_schema)) {
        return error.InvalidStorageRootMarker;
    }
    if (!std.mem.eql(u8, marker.value.store_id, expected_id)) {
        return error.StorageRootIdentityMismatch;
    }
}

test "legacy custody arguments remain unchanged" {
    const argv = [_][]const u8{ "ledger", "doctor", "--repo", "relative" };
    var selection = try prepare(std.testing.allocator, std.testing.io, &argv);
    defer selection.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices([]const u8, &argv, selection.argv);
}

test "managed roots reject ambiguous selectors before accessing storage" {
    try std.testing.expectError(error.ConflictingStorageRoots, prepare(
        std.testing.allocator,
        std.testing.io,
        &.{ "ledger", "doctor", "--repo", ".", "--store-root", "/tmp/a", "--store-id", "a" },
    ));
    try std.testing.expectError(error.MissingStoreIdentity, prepare(
        std.testing.allocator,
        std.testing.io,
        &.{ "ledger", "doctor", "--store-root", "/tmp/a" },
    ));
    try std.testing.expectError(error.StorageRootRequiresDurableCommand, prepare(
        std.testing.allocator,
        std.testing.io,
        &.{ "ledger", "validate", "--store-root", "/tmp/a", "--store-id", "a" },
    ));
}

test "managed root verifies identity and preserves native argument values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".ledger", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = marker_name,
        .data = "{\"schema\":\"ledger-storage-root/v1\",\"store_id\":\"example\"}",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var selected = try prepare(std.testing.allocator, std.testing.io, &.{
        "ledger",
        "project",
        "--store-root",
        root,
        "--store-id",
        "example",
        "--param",
        "query=two words",
        "--projection",
        "recent",
    });
    defer selected.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("--repo", selected.argv[2]);
    try std.testing.expectEqualStrings(root, selected.argv[3]);
    try std.testing.expectEqualStrings("query=two words", selected.argv[5]);
    try std.testing.expectError(error.StorageRootIdentityMismatch, prepare(
        std.testing.allocator,
        std.testing.io,
        &.{ "ledger", "doctor", "--store-root", root, "--store-id", "different" },
    ));
}

test "existing directory cannot masquerade as an initialized managed store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.expectError(error.StorageRootUnregistered, prepare(
        std.testing.allocator,
        std.testing.io,
        &.{ "ledger", "doctor", "--store-root", root, "--store-id", "example" },
    ));
}
