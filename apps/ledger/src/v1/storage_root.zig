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

    pub fn readFile(
        self: *Scope,
        allocator: std.mem.Allocator,
        path: []const u8,
        max_bytes: usize,
    ) ![]u8 {
        return durable_store.readRegularFileNoSymlink(self.fs, allocator, path, max_bytes);
    }
};

pub const ReadBudget = durable_store.ReadBudget;

pub const Selection = struct {
    argv: []const []const u8,
    control: ?std.Io.Dir = null,
    io: std.Io,
    supplied_root: ?[]const u8 = null,
    store_id: ?[]const u8 = null,

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
        if (self.control) |control| scope.fs = scope.fs.reanchor(control);
    }

    pub fn revalidate(self: *const Selection, allocator: std.mem.Allocator) !void {
        return self.revalidateBudgeted(allocator, null);
    }

    pub fn revalidateBudgeted(
        self: *const Selection,
        allocator: std.mem.Allocator,
        budget: ?*ReadBudget,
    ) !void {
        const control = self.control orelse return error.PreparationRequiresManagedTarget;
        const current = try checkedRootBudgeted(
            allocator,
            self.io,
            self.supplied_root.?,
            self.store_id.?,
            budget,
        );
        defer current.close(self.io);
        if ((try control.stat(self.io)).inode != (try current.stat(self.io)).inode) {
            return error.PreparationTargetChanged;
        }
    }
};

pub fn controlComponent(scope: *const Scope) []const u8 {
    return if (scope.fs.isPinned()) "." else ".ledger";
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
        .supplied_root = root_arg,
        .store_id = expected_id,
    };
}

fn isDurableCommand(command: []const u8) bool {
    for ([_][]const u8{
        "transact",
        "project",
        "doctor",
        "migrate-segmented",
        "recovery",
        "prepare",
        "maintain",
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
        "--source-root",
        "--source-store",
        "--source-archive",
        "--max-bytes",
        "--max-files",
        "--max-read-bytes",
    }) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

pub fn checkedRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    supplied_root: []const u8,
    expected_id: []const u8,
) !std.Io.Dir {
    return checkedRootBudgeted(allocator, io, supplied_root, expected_id, null);
}

pub fn checkedRootBudgeted(
    allocator: std.mem.Allocator,
    io: std.Io,
    supplied_root: []const u8,
    expected_id: []const u8,
    budget: ?*ReadBudget,
) !std.Io.Dir {
    if (expected_id.len == 0 or expected_id.len > 256) return error.InvalidStoreIdentity;
    var root_dir = try openRoot(io, supplied_root);
    defer root_dir.close(io);
    const control = root_dir.openDir(io, ".ledger", .{
        .follow_symlinks = false,
    }) catch |err| {
        try checkMarker(allocator, io, root_dir, expected_id, budget);
        return switch (err) {
            error.FileNotFound => error.StorageRootMissing,
            error.NotDir => error.StorageRootNotDirectory,
            error.SymLinkLoop => error.SymlinkComponent,
            else => err,
        };
    };
    errdefer control.close(io);
    try checkMarker(allocator, io, root_dir, expected_id, budget);
    return control;
}

pub fn openRoot(io: std.Io, supplied_root: []const u8) !std.Io.Dir {
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
    budget: ?*ReadBudget,
) !void {
    var uncounted: ReadBudget = .{ .max_bytes = 4097, .max_files = 1 };
    var fs = durable_store.Fs.anchored(io, root);
    fs.read_budget = budget orelse &uncounted;
    const bytes = durable_store.readRegularFileNoSymlink(
        fs,
        allocator,
        marker_name,
        4096,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.StorageRootUnregistered,
        error.NotFile, error.FileTooBig, error.StreamTooLong => {
            return error.InvalidStorageRootMarker;
        },
        else => return err,
    };
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
    var budget: ReadBudget = .{ .max_bytes = 4096, .max_files = 1 };
    scope.fs.read_budget = &budget;
    try std.testing.expect(!isActive(&scope));
    selected.enterControl(&scope);
    try std.testing.expectEqual(&budget, scope.fs.read_budget.?);
    try selected.revalidateBudgeted(std.testing.allocator, scope.fs.read_budget);
    try std.testing.expect(budget.bytes > 0);
    try std.testing.expectEqual(@as(usize, 1), budget.files);
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

const BoundedReadMutationTest = struct {
    const Change = enum { grow, truncate, replace };
    var directory: std.Io.Dir = undefined;
    var change: Change = .grow;
    var changed = false;
    var mutation_error: ?anyerror = null;
    var observed_bytes: usize = 0;
    var requested_bytes: usize = 0;

    fn configure(dir: std.Io.Dir, mode: Change, vtable: *std.Io.VTable) std.Io {
        directory = dir;
        change = mode;
        changed = false;
        mutation_error = null;
        observed_bytes = 0;
        requested_bytes = 0;
        vtable.* = std.testing.io.vtable.*;
        vtable.fileStat = stat;
        vtable.fileReadPositional = read;
        return .{ .userdata = std.testing.io.userdata, .vtable = vtable };
    }

    fn stat(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
        const result = try std.testing.io.vtable.fileStat(userdata, file);
        if (!changed) {
            changed = true;
            mutate() catch |err| {
                mutation_error = err;
                return error.Unexpected;
            };
        }
        return result;
    }

    fn mutate() !void {
        const bytes: []const u8 = switch (change) {
            .grow => "abcdefghij",
            .truncate => "ab",
            .replace => blk: {
                try directory.rename("selected", directory, "opened-original", std.testing.io);
                break :blk "replacement";
            },
        };
        try directory.writeFile(std.testing.io, .{ .sub_path = "selected", .data = bytes });
    }

    fn read(
        userdata: ?*anyopaque,
        file: std.Io.File,
        buffers: []const []u8,
        offset: u64,
    ) std.Io.File.ReadPositionalError!usize {
        for (buffers) |buffer| requested_bytes += buffer.len;
        const count = try std.testing.io.vtable.fileReadPositional(userdata, file, buffers, offset);
        observed_bytes += count;
        return count;
    }
};

test "bounded preparation reads charge rejected growth against aggregate limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "selected", .data = "a" });
    var vtable: std.Io.VTable = undefined;
    const io = BoundedReadMutationTest.configure(tmp.dir, .grow, &vtable);
    var budget: ReadBudget = .{ .max_bytes = 9, .max_files = 2 };
    var scope: Scope = .{ .fs = .anchored(io, tmp.dir) };
    scope.fs.read_budget = &budget;
    try std.testing.expectError(error.FileTooBig, scope.readFile(
        std.testing.allocator,
        "selected",
        4,
    ));
    try std.testing.expect(BoundedReadMutationTest.changed);
    try std.testing.expectEqual(null, BoundedReadMutationTest.mutation_error);
    try std.testing.expectEqual(@as(usize, 5), budget.bytes);
    try std.testing.expectEqual(@as(usize, 5), BoundedReadMutationTest.observed_bytes);
    try std.testing.expectEqual(@as(usize, 5), BoundedReadMutationTest.requested_bytes);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "selected", .data = "a" });
    BoundedReadMutationTest.changed = false;
    try std.testing.expectError(error.ReadBudgetExceeded, scope.readFile(
        std.testing.allocator,
        "selected",
        4,
    ));
    try std.testing.expect(BoundedReadMutationTest.changed);
    try std.testing.expectEqual(null, BoundedReadMutationTest.mutation_error);
    try std.testing.expectEqual(@as(usize, 9), budget.bytes);
    try std.testing.expectEqual(@as(usize, 9), BoundedReadMutationTest.observed_bytes);
    try std.testing.expectEqual(@as(usize, 9), BoundedReadMutationTest.requested_bytes);
    try std.testing.expectEqual(@as(usize, 2), budget.files);
    try std.testing.expectError(error.ReadFileBudgetExceeded, scope.readFile(
        std.testing.allocator,
        "selected",
        4,
    ));
    try std.testing.expectEqual(@as(usize, 9), BoundedReadMutationTest.observed_bytes);
}

test "bounded preparation reads measure truncation from the opened stream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "selected", .data = "abcdef" });
    var vtable: std.Io.VTable = undefined;
    const io = BoundedReadMutationTest.configure(tmp.dir, .truncate, &vtable);
    var budget: ReadBudget = .{ .max_bytes = 32, .max_files = 1 };
    var scope: Scope = .{ .fs = .anchored(io, tmp.dir) };
    scope.fs.read_budget = &budget;
    const bytes = try scope.readFile(std.testing.allocator, "selected", 6);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(BoundedReadMutationTest.changed);
    try std.testing.expectEqual(null, BoundedReadMutationTest.mutation_error);
    try std.testing.expectEqualStrings("ab", bytes);
    try std.testing.expectEqual(@as(usize, 2), budget.bytes);
    try std.testing.expectEqual(@as(usize, 2), BoundedReadMutationTest.observed_bytes);
    try std.testing.expectEqual(@as(usize, 1), budget.files);
}

test "bounded preparation reads preserve opened bytes after pathname replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "selected", .data = "before" });
    var vtable: std.Io.VTable = undefined;
    const io = BoundedReadMutationTest.configure(tmp.dir, .replace, &vtable);
    var budget: ReadBudget = .{ .max_bytes = 32, .max_files = 1 };
    var scope: Scope = .{ .fs = .anchored(io, tmp.dir) };
    scope.fs.read_budget = &budget;
    const bytes = try scope.readFile(std.testing.allocator, "selected", 6);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(BoundedReadMutationTest.changed);
    try std.testing.expectEqual(null, BoundedReadMutationTest.mutation_error);
    try std.testing.expectEqualStrings("before", bytes);
    try std.testing.expectEqual(@as(usize, 6), budget.bytes);
    try std.testing.expectEqual(@as(usize, 6), BoundedReadMutationTest.observed_bytes);
    const replacement = try tmp.dir.readFileAlloc(
        std.testing.io,
        "selected",
        std.testing.allocator,
        .limited(32),
    );
    defer std.testing.allocator.free(replacement);
    try std.testing.expectEqualStrings("replacement", replacement);
}

test "bounded preparation reads reject symlinks and special files before payload reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "selected", .data = "before" });
    try tmp.dir.symLink(std.testing.io, "selected", "link", .{});
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const fifo = try std.fs.path.join(std.testing.allocator, &.{ root, "fifo" });
    defer std.testing.allocator.free(fifo);
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "mkfifo", fifo },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.MkfifoFailed;
    var budget: ReadBudget = .{ .max_bytes = 32, .max_files = 2 };
    var scope: Scope = .{ .fs = .anchored(std.testing.io, tmp.dir) };
    scope.fs.read_budget = &budget;
    try std.testing.expectError(error.SymlinkComponent, scope.readFile(
        std.testing.allocator,
        "link",
        32,
    ));
    try std.testing.expectError(error.NotFile, scope.readFile(
        std.testing.allocator,
        "fifo",
        32,
    ));
    try std.testing.expectEqual(@as(usize, 0), budget.bytes);
    try std.testing.expectEqual(@as(usize, 2), budget.files);
}
