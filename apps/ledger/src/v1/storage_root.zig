const std = @import("std");
const durable_store = @import("durable_store");

pub const marker_name = ".ledger-root.json";
const marker_schema = "ledger-storage-root/v1";

/// Borrowed filesystem authority for one operation. Selection owns any managed
/// directory handle; scopes neither replace process cwd nor own those handles.
/// Keep this scope stable and its owning selection alive until all stores,
/// snapshots, scans, locks, and transactions borrowing it have completed.
pub const Scope = struct {
    fs: durable_store.Fs,
    mutation_state: ?bool = false,

    pub fn init(fs: durable_store.Fs) Scope {
        return .{ .fs = fs };
    }
};

pub const Selection = struct {
    argv: []const []const u8,
    control: ?std.Io.Dir = null,
    io: std.Io,

    pub fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
        if (self.control) |control| control.close(self.io);
        self.* = undefined;
    }

    pub fn invocationScope(self: *const Selection, invocation_dir: std.Io.Dir) Scope {
        return .init(.init(self.io, invocation_dir));
    }

    /// Enter only after command input paths have been read in invocation scope.
    pub fn enterControl(self: *const Selection, scope: *Scope) void {
        if (self.control) |control| scope.fs = .anchored(self.io, control);
    }
};

pub fn controlComponent(scope: *const Scope) []const u8 {
    return if (scope.fs.isPinned()) "." else ".ledger";
}

pub fn controlPathAlloc(
    scope: *const Scope,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) ![]u8 {
    return std.fs.path.join(allocator, &.{ repo_root, controlComponent(scope) });
}

pub fn isActive(scope: *const Scope) bool {
    return scope.fs.isPinned();
}

pub fn validRepoRoot(scope: *const Scope, path: []const u8) bool {
    return std.fs.path.isAbsolute(path) or
        (scope.fs.isPinned() and std.mem.eql(u8, path, "."));
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
    if (!hasSelector(argv)) return .{ .argv = try allocator.dupe([]const u8, argv), .io = io };
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
    if (expected_id.len == 0 or expected_id.len > 256) return error.InvalidStoreIdentity;
    var admitted = try SourceRoot.open(allocator, io, supplied_root, expected_id);
    defer admitted.deinit();
    const control = admitted.control orelse return error.StorageRootMissing;
    admitted.control = null;
    return control;
}

pub const SourceRoot = struct {
    allocator: std.mem.Allocator,
    locator: []u8,
    directory: std.Io.Dir,
    control: ?std.Io.Dir,
    io: std.Io,
    store_id: ?[]u8,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        supplied_root: []const u8,
        expected_id: ?[]const u8,
    ) !SourceRoot {
        if (expected_id) |id| {
            if (id.len == 0 or id.len > 256) return error.InvalidStoreIdentity;
        }
        const directory = try openRootDirectory(io, supplied_root);
        errdefer directory.close(io);
        if (expected_id) |id| try checkMarker(allocator, io, directory, id);
        const control = directory.openDir(io, ".ledger", .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => absent: {
                if (expected_id != null) return error.StorageRootMissing;
                break :absent null;
            },
            error.NotDir => return error.StorageRootNotDirectory,
            error.SymLinkLoop => return error.SymlinkComponent,
            else => return err,
        };
        errdefer if (control) |opened| opened.close(io);
        const locator = try allocator.dupe(u8, supplied_root);
        errdefer allocator.free(locator);
        return .{
            .allocator = allocator,
            .locator = locator,
            .directory = directory,
            .control = control,
            .io = io,
            .store_id = if (expected_id) |id| try allocator.dupe(u8, id) else null,
        };
    }

    pub fn deinit(self: *SourceRoot) void {
        if (self.control) |control| control.close(self.io);
        self.directory.close(self.io);
        self.allocator.free(self.locator);
        if (self.store_id) |id| self.allocator.free(id);
        self.* = undefined;
    }

    pub fn scope(self: *const SourceRoot) ?Scope {
        return .init(.anchored(self.io, self.control orelse return null));
    }

    pub fn prepareControlForApply(self: *SourceRoot, storage_mutated: *bool) !void {
        if (self.control != null) return self.revalidateControl();
        try self.revalidateRoot(self.locator);
        try durable_store.ensureDirectoryPathNoSymlinksObserved(
            .anchored(self.io, self.directory),
            ".ledger",
            storage_mutated,
        );
        self.control = try self.directory.openDir(self.io, ".ledger", .{
            .follow_symlinks = false,
        });
        try self.revalidateControl();
    }

    pub fn openControlFile(self: *const SourceRoot, path: []const u8) !std.Io.File {
        const control = self.control orelse return error.StorageRootMissing;
        if (path.len == 0 or std.fs.path.isAbsolute(path) or path[path.len - 1] == '/') {
            return error.InvalidSourcePath;
        }
        var parent = try control.openDir(self.io, ".", .{ .follow_symlinks = false });
        defer parent.close(self.io);
        var components = std.mem.splitScalar(u8, path, '/');
        while (components.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or
                std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, 0) != null)
            {
                return error.InvalidSourcePath;
            }
            if (components.peek() == null) return openRegularLeaf(self.io, parent, part);
            const next = try parent.openDir(self.io, part, .{ .follow_symlinks = false });
            parent.close(self.io);
            parent = next;
        }
        return error.InvalidSourcePath;
    }

    pub fn revalidate(self: *const SourceRoot, locator: []const u8) !void {
        if (!std.mem.eql(u8, locator, self.locator)) try self.revalidateRoot(locator);
        try self.revalidateControl();
    }

    fn revalidateRoot(self: *const SourceRoot, locator: []const u8) !void {
        const current = try openRootDirectory(self.io, locator);
        defer current.close(self.io);
        try sameDirectory(self.io, self.directory, current);
        if (self.store_id) |id| try checkMarker(self.allocator, self.io, current, id);
    }

    pub fn revalidateControl(self: *const SourceRoot) !void {
        try self.revalidateRoot(self.locator);
        try self.revalidateOpenedControl();
    }

    fn revalidateOpenedControl(self: *const SourceRoot) !void {
        const current = self.directory.openDir(self.io, ".ledger", .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                if (self.control == null) return;
                return error.PreparationSourceChanged;
            },
            error.NotDir, error.SymLinkLoop => return error.PreparationSourceChanged,
            else => return err,
        };
        defer current.close(self.io);
        const expected = self.control orelse return error.PreparationSourceChanged;
        try sameDirectory(self.io, expected, current);
    }
};

fn openRegularLeaf(io: std.Io, parent: std.Io.Dir, leaf: []const u8) !std.Io.File {
    return durable_store.openRegularFileNoSymlink(.anchored(io, parent), leaf);
}

fn sameDirectory(io: std.Io, expected: std.Io.Dir, current: std.Io.Dir) !void {
    const before = try durable_store.openDirectoryIdentity(io, expected);
    const after = try durable_store.openDirectoryIdentity(io, current);
    if (!std.meta.eql(before, after)) return error.PreparationSourceChanged;
}

fn openRootDirectory(io: std.Io, supplied_root: []const u8) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(supplied_root)) return error.StorageRootNotAbsolute;
    var root_dir = try std.Io.Dir.openDirAbsolute(io, "/", .{
        .follow_symlinks = false,
    });
    errdefer root_dir.close(io);
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
    return root_dir;
}

fn checkMarker(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    expected_id: []const u8,
) !void {
    // The supplied root handle authorizes this host-only open. std.Io does not
    // expose O_NONBLOCK, which is required to reject FIFO markers without waiting.
    // Every operation on the resulting file uses the caller's I/O implementation.
    const marker_fd = std.posix.openat(root.handle, marker_name, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound => return error.StorageRootUnregistered,
        error.SymLinkLoop => return error.SymlinkComponent,
        else => return err,
    };
    var file: std.Io.File = .{
        .handle = marker_fd,
        .flags = .{ .nonblocking = true },
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
    var scope = selected.invocationScope(tmp.dir);
    try std.testing.expect(!isActive(&scope));
    selected.enterControl(&scope);
    try std.testing.expect(isActive(&scope));
    try std.testing.expectEqual(selected.control.?.handle, scope.fs.directory().handle);
    try std.testing.expectEqualStrings(".", controlComponent(&scope));
    try std.testing.expect(validRepoRoot(&scope, "."));
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

test "registered managed root requires its control directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = marker_name,
        .data = "{\"schema\":\"ledger-storage-root/v1\",\"store_id\":\"example\"}",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.expectError(error.StorageRootMissing, prepare(
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

fn prepareAllocationProbe(allocator: std.mem.Allocator, root: []const u8) !void {
    var selected = prepare(allocator, std.testing.io, &.{
        "ledger", "doctor", "--store-root", root, "--store-id", "allocation-probe",
    }) catch |err| switch (err) {
        // Marker admission intentionally classifies parser failures uniformly.
        // This fixture is valid, so this failure can only be injected OOM.
        error.InvalidStorageRootMarker => return error.OutOfMemory,
        else => return err,
    };
    defer selected.deinit(allocator);
    var scope = selected.invocationScope(std.Io.Dir.cwd());
    selected.enterControl(&scope);
    try std.testing.expect(scope.fs.isPinned());
}

test "managed admission cleans up every partial allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".ledger", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = marker_name,
        .data = "{\"schema\":\"ledger-storage-root/v1\",\"store_id\":\"allocation-probe\"}",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        prepareAllocationProbe,
        .{root},
    );
}

test "managed admission propagates supplied I/O cancellation" {
    const Cancelled = struct {
        fn openDir(
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: std.Io.Dir.OpenOptions,
        ) std.Io.Dir.OpenError!std.Io.Dir {
            return error.Canceled;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.dirOpenDir = Cancelled.openDir;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.Canceled, prepare(std.testing.allocator, io, &.{
        "ledger", "doctor", "--store-root", "/", "--store-id", "cancelled",
    }));
}

test "source admission retains selected root and rejects replacement" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "source/.ledger");
    try tmp.dir.writeFile(io, .{ .sub_path = "source/.ledger/value", .data = "original" });
    const locator = try tmp.dir.realPathFileAlloc(io, "source", allocator);
    defer allocator.free(locator);
    var source = try SourceRoot.open(allocator, io, locator, null);
    defer source.deinit();
    try source.revalidate(locator);
    try tmp.dir.rename("source", tmp.dir, "moved", io);
    try tmp.dir.createDirPath(io, "source/.ledger");
    try tmp.dir.writeFile(io, .{ .sub_path = "source/.ledger/value", .data = "replacement" });
    try std.testing.expectError(error.PreparationSourceChanged, source.revalidate(locator));
    const source_scope = source.scope().?;
    const bytes = try durable_store.readRegularFileNoSymlink(
        source_scope.fs,
        allocator,
        "value",
        32,
    );
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("original", bytes);
}

test "source admission observes a control directory appearing or changing" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const locator = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(locator);
    var empty = try SourceRoot.open(allocator, io, locator, null);
    defer empty.deinit();
    try std.testing.expectEqual(null, empty.scope());
    try empty.revalidate(locator);
    try tmp.dir.createDir(io, ".ledger", .default_dir);
    try std.testing.expectError(error.PreparationSourceChanged, empty.revalidate(locator));
    var present = try SourceRoot.open(allocator, io, locator, null);
    defer present.deinit();
    try tmp.dir.rename(".ledger", tmp.dir, "old-control", io);
    try tmp.dir.createDir(io, ".ledger", .default_dir);
    try std.testing.expectError(error.PreparationSourceChanged, present.revalidate(locator));
}

test "source file handles reject traversal and symlinks and survive path replacement" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".ledger/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ledger/nested/value", .data = "original" });
    try tmp.dir.symLink(io, "value", ".ledger/nested/link", .{});
    const locator = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(locator);
    var source = try SourceRoot.open(allocator, io, locator, null);
    defer source.deinit();
    const invalid_paths = [_][]const u8{
        "", "/nested/value", "../value", "nested/../value", "nested//value",
    };
    for (invalid_paths) |path| {
        try std.testing.expectError(error.InvalidSourcePath, source.openControlFile(path));
    }
    try std.testing.expectError(error.SymlinkComponent, source.openControlFile("nested/link"));
    try std.testing.expectError(error.NotFile, source.openControlFile("nested"));
    const file = try source.openControlFile("nested/value");
    defer file.close(io);
    try tmp.dir.rename(".ledger/nested", tmp.dir, "old", io);
    try tmp.dir.createDirPath(io, ".ledger/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ledger/nested/value", .data = "new" });
    var reader = file.reader(io, &.{});
    const bytes = try reader.interface.allocRemaining(allocator, .limited(32));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("original", bytes);
}

test "source revalidation checks its admitted managed identity" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, ".ledger", .default_dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = marker_name,
        .data = "{\"schema\":\"ledger-storage-root/v1\",\"store_id\":\"original\"}",
    });
    const locator = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(locator);
    var source = try SourceRoot.open(allocator, io, locator, "original");
    defer source.deinit();
    try source.revalidate(locator);
    try tmp.dir.writeFile(io, .{
        .sub_path = marker_name,
        .data = "{\"schema\":\"ledger-storage-root/v1\",\"store_id\":\"replacement\"}",
    });
    try std.testing.expectError(error.StorageRootIdentityMismatch, source.revalidate(locator));
    try std.testing.expectError(error.StorageRootIdentityMismatch, source.revalidateControl());
}

test "control revalidation retains the admitted root locator" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "source/.ledger");
    const locator = try tmp.dir.realPathFileAlloc(io, "source", allocator);
    defer allocator.free(locator);
    var source = try SourceRoot.open(allocator, io, locator, null);
    defer source.deinit();
    try source.revalidateControl();
    try tmp.dir.rename("source", tmp.dir, "original", io);
    try tmp.dir.createDirPath(io, "source/.ledger");
    try std.testing.expectError(error.PreparationSourceChanged, source.revalidateControl());
}

test "apply rejects an empty replaced root before creating coordination state" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "source", .default_dir);
    const locator = try tmp.dir.realPathFileAlloc(io, "source", allocator);
    defer allocator.free(locator);
    var source = try SourceRoot.open(allocator, io, locator, null);
    defer source.deinit();
    try tmp.dir.rename("source", tmp.dir, "original", io);
    try tmp.dir.createDir(io, "source", .default_dir);
    var mutated = false;
    try std.testing.expectError(error.PreparationSourceChanged, source.prepareControlForApply(
        &mutated,
    ));
    try std.testing.expect(!mutated);
    for ([_][]const u8{ "source/.ledger", "original/.ledger" }) |path| {
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, path, .{
            .follow_symlinks = false,
        }));
    }
}
