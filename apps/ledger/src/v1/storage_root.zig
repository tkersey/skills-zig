const std = @import("std");
const durable_store = @import("durable_store");

pub const marker_name = ".ledger-root.json";
const marker_schema = "ledger-storage-root/v1";

pub const Selection = struct {
    argv: []const []const u8,
    control: ?std.Io.Dir = null,
    io: ?std.Io = null,

    pub fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
        if (self.control) |control| control.close(self.io.?);
        self.* = undefined;
    }
};

threadlocal var pending_control: ?std.Io.Dir = null;
threadlocal var active_control: ?std.Io.Dir = null;

pub fn install(selection: *const Selection) void {
    pending_control = selection.control;
}

pub fn uninstall() void {
    durable_store.setRelativePathAnchor(false);
    active_control = null;
    pending_control = null;
}

pub fn enterControl() !bool {
    active_control = pending_control;
    if (active_control) |control| {
        if (std.Io.Dir.cwd().handle != control.handle) {
            active_control = null;
            return error.ManagedRootNotAnchored;
        }
    }
    durable_store.setRelativePathAnchor(active_control != null);
    return active_control != null;
}

pub fn leaveControl() void {
    durable_store.setRelativePathAnchor(false);
    active_control = null;
}

pub fn currentCwd() std.Io.Dir {
    return active_control orelse .{ .handle = std.posix.AT.FDCWD };
}

pub fn controlComponent() []const u8 {
    return if (active_control != null) "." else ".ledger";
}

pub fn isActive() bool {
    return active_control != null;
}

pub fn validRepoRoot(path: []const u8) bool {
    return std.fs.path.isAbsolute(path) or
        (active_control != null and std.mem.eql(u8, path, "."));
}

pub fn hasSelector(argv: []const []const u8) bool {
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--store-root") or
            std.mem.eql(u8, arg, "--store-id")) return true;
        if (takesValue(arg)) index += 1;
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
    const control = try checkedRoot(
        allocator,
        io,
        root_arg orelse return error.MissingStorageRoot,
        expected_id orelse return error.MissingStoreIdentity,
    );
    errdefer control.close(io);
    args.items[root_index.?] = ".";
    return .{
        .argv = try args.toOwnedSlice(allocator),
        .control = control,
        .io = io,
    };
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
        "--repo",
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
) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(supplied_root)) return error.StorageRootNotAbsolute;
    if (expected_id.len == 0 or expected_id.len > 256) return error.InvalidStoreIdentity;
    var root_dir = try std.Io.Dir.openDirAbsolute(io, "/", .{
        .follow_symlinks = false,
    });
    defer root_dir.close(io);
    var components = std.fs.path.componentIterator(supplied_root);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component.name, ".") or
            std.mem.eql(u8, component.name, ".."))
        {
            return error.InvalidStorageRootPath;
        }
        const next = root_dir.openDir(io, component.name, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.StorageRootMissing,
            error.NotDir => return error.StorageRootNotDirectory,
            error.SymLinkLoop => return error.SymlinkComponent,
            else => return err,
        };
        root_dir.close(io);
        root_dir = next;
    }
    const control = root_dir.openDir(io, ".ledger", .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.StorageRootMissing,
        error.NotDir => return error.StorageRootNotDirectory,
        error.SymLinkLoop => return error.SymlinkComponent,
        else => return err,
    };
    errdefer control.close(io);
    try checkMarker(allocator, io, root_dir, expected_id);
    return control;
}

fn checkMarker(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    expected_id: []const u8,
) !void {
    var file = root.openFile(io, marker_name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.StorageRootUnregistered,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > 4096) return error.InvalidStorageRootMarker;
    var reader = file.reader(io, &.{});
    const bytes = try reader.interface.allocRemaining(allocator, .limited(4096));
    defer allocator.free(bytes);
    const Marker = struct { schema: []const u8, store_id: []const u8 };
    var marker = std.json.parseFromSlice(Marker, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch
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

test "selector words in native option values do not select managed mode" {
    const argv = [_][]const u8{
        "ledger",       "project",    "--repo", "relative", "--projection", "--store-root",
        "--definition", "--store-id",
    };
    try std.testing.expect(!hasSelector(&argv));
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
    try std.testing.expectEqualStrings(".", selected.argv[3]);
    try std.testing.expect(selected.control != null);
    try std.testing.expectEqualStrings("query=two words", selected.argv[5]);
    install(&selected);
    defer uninstall();
    try std.testing.expectError(error.ManagedRootNotAnchored, enterControl());
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

test "duplicate marker identity fields are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".ledger", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = marker_name,
        .data = "{\"schema\":\"ledger-storage-root/v1\"," ++
            "\"store_id\":\"example\",\"store_id\":\"other\"}",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.expectError(error.InvalidStorageRootMarker, prepare(
        std.testing.allocator,
        std.testing.io,
        &.{ "ledger", "doctor", "--store-root", root, "--store-id", "example" },
    ));
}
