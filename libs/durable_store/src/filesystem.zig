const staged_file = @import("staged_file.zig");
const std = @import("std");
const jsonl_core = @import("jsonl_core");
const fs_authority = @import("fs_authority.zig");
const Fs = fs_authority.Fs;
const event = @import("event.zig");
const EventAppendReceipt = event.EventAppendReceipt;
const EventHash = event.EventHash;
const EventRecordVisitor = event.EventRecordVisitor;
const EventScanSummary = event.EventScanSummary;
const emptyEventScanSummary = event.emptyEventScanSummary;
const eventAppendReceipt = event.eventAppendReceipt;
const ignoreEventRecord = event.ignoreEventRecord;
const scanEventReader = event.scanEventReader;
const record_codec = @import("record_codec.zig");
const JsonlValidation = record_codec.JsonlValidation;
const event_store_lock_dir_name = record_codec.event_store_lock_dir_name;
const lockPathAlloc = record_codec.lockPathAlloc;
const rejectEventStoreControlNamespace = record_codec.rejectEventStoreControlNamespace;
const validateJsonlBytes = record_codec.validateJsonlBytes;

const GitCheckOutputLimit = 4 * 1024;
const directory_case_probe_attempts_max: usize = 3;

// Bound raw syscall retries under persistent signal interruption.

const host_syscall_attempts_max: usize = 64;

pub const CreateNewOptions = struct {
    reject_symlinks: bool = true,
    file_mode: ?u32 = 0o600,
    sync: bool = true,
};

pub const AppendLineOptions = struct {
    reject_symlinks: bool = true,
    file_mode: ?u32 = 0o600,
    sync: bool = true,
};

const ClockKind = enum { awake, real };

pub fn clockMillis(fs: Fs, kind: ClockKind) u64 {
    const now = switch (kind) {
        .awake => std.Io.Clock.awake.now(fs.io),
        .real => std.Io.Clock.real.now(fs.io),
    };
    return @as(u64, @intCast(@divFloor(now.nanoseconds, 1_000_000)));
}

pub fn elapsedMillis(fs: Fs, start_ms: u64) u64 {
    const now = clockMillis(fs, .awake);
    if (now <= start_ms) return 0;
    return now - start_ms;
}

fn leaseAdvisoryPathAlloc(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
) ![]u8 {
    return allocator.print(
        "{s}.advisory",
        .{lock_path},
    );
}

pub fn acquireLeaseAdvisoryLock(
    fs: Fs,
    allocator: std.mem.Allocator,
    lock_path: []const u8,
) !std.Io.File {
    return acquireLeaseAdvisoryLockObserved(
        fs,
        allocator,
        lock_path,
        null,
    );
}

pub fn acquireLeaseAdvisoryLockObserved(
    fs: Fs,
    allocator: std.mem.Allocator,
    lock_path: []const u8,
    storage_mutated: ?*bool,
) !std.Io.File {
    const advisory_path = try leaseAdvisoryPathAlloc(
        allocator,
        lock_path,
    );
    defer allocator.free(advisory_path);
    var created = false;
    const lock = openEventStoreSidecarExclusiveObserved(
        fs,
        advisory_path,
        &created,
    ) catch |err| switch (err) {
        error.WouldBlock => return error.LockBusy,
        else => return err,
    };
    if (created) {
        if (storage_mutated) |mutated| mutated.* = true;
    }
    return lock;
}

pub const HostPathIdentityContext = struct {
    const DirectoryIdentity = struct {
        canonical: []u8,
        case_insensitive: bool,
    };

    allocator: std.mem.Allocator,
    directories: std.StringHashMap(DirectoryIdentity),
    fs: Fs,

    pub fn init(fs: Fs, allocator: std.mem.Allocator) HostPathIdentityContext {
        return .{
            .fs = fs,
            .allocator = allocator,
            .directories = std.StringHashMap(DirectoryIdentity).init(
                allocator,
            ),
        };
    }

    pub fn deinit(self: *HostPathIdentityContext) void {
        var entries = self.directories.iterator();
        while (entries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.canonical);
        }
        self.directories.deinit();
        self.* = undefined;
    }

    fn directoryIdentity(
        self: *HostPathIdentityContext,
        directory: []const u8,
        witness_name: []const u8,
    ) !DirectoryIdentity {
        const fs = self.fs;
        const resolved = try std.fs.path.resolve(
            self.allocator,
            &.{directory},
        );
        defer self.allocator.free(resolved);
        if (self.directories.get(resolved)) |identity| return identity;
        const key = try self.allocator.dupe(u8, resolved);
        errdefer self.allocator.free(key);
        const canonical = try canonicalProspectivePathAlloc(
            fs,
            self.allocator,
            resolved,
        );
        errdefer self.allocator.free(canonical);
        const case_insensitive = try directoryNameIsCaseInsensitive(
            fs,
            self.allocator,
            canonical,
            witness_name,
        );
        if (case_insensitive) {
            for (canonical) |*byte| byte.* = std.ascii.toLower(byte.*);
        }
        const identity: DirectoryIdentity = .{
            .canonical = canonical,
            .case_insensitive = case_insensitive,
        };
        try self.directories.put(key, identity);
        return identity;
    }

    pub fn canonicalAlloc(
        self: *HostPathIdentityContext,
        path: []const u8,
    ) ![]u8 {
        const fs = self.fs;
        const resolved = try std.fs.path.resolve(
            self.allocator,
            &.{path},
        );
        defer self.allocator.free(resolved);
        const parent = std.fs.path.dirname(resolved) orelse
            return error.InvalidPath;
        const directory = try self.directoryIdentity(
            parent,
            std.fs.path.basename(resolved),
        );
        if (containsNonAscii(std.fs.path.basename(resolved)) and
            !(fs.isPinned() and !std.fs.path.isAbsolute(resolved)))
        {
            const host_canonical = fs.directory().realPathFileAlloc(
                fs.io,
                resolved,
                self.allocator,
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    if (directory.case_insensitive) {
                        return error.TransactionRecoveryRequired;
                    }
                    return std.fs.path.join(
                        self.allocator,
                        &.{
                            directory.canonical,
                            std.fs.path.basename(resolved),
                        },
                    );
                },
                else => return err,
            };
            defer self.allocator.free(host_canonical);
            const canonical = try self.allocator.dupe(u8, host_canonical);
            if (directory.case_insensitive) {
                for (canonical) |*byte| {
                    byte.* = std.ascii.toLower(byte.*);
                }
            }
            return canonical;
        }
        const canonical = try std.fs.path.join(
            self.allocator,
            &.{ directory.canonical, std.fs.path.basename(resolved) },
        );
        if (directory.case_insensitive) {
            for (canonical) |*byte| byte.* = std.ascii.toLower(byte.*);
        }
        return canonical;
    }

    pub fn objectKeyAlloc(
        self: *HostPathIdentityContext,
        path: []const u8,
    ) ![]u8 {
        const fs = self.fs;
        if (@import("builtin").os.tag == .windows) {
            const canonical = try self.canonicalAlloc(path);
            defer self.allocator.free(canonical);
            return self.allocator.print(
                "path:{s}",
                .{canonical},
            );
        }
        const resolved = try std.fs.path.resolve(
            self.allocator,
            &.{path},
        );
        defer self.allocator.free(resolved);
        var candidate = try self.allocator.dupe(u8, resolved);
        defer self.allocator.free(candidate);
        while (candidate.len != 0) {
            if (try hostObjectIdentity(fs, candidate)) |identity| {
                if (std.mem.eql(u8, candidate, resolved)) {
                    return self.allocator.print(
                        "object:{d}:{d}",
                        .{ identity.device, identity.inode },
                    );
                }
                return self.prospectiveObjectKeyAlloc(candidate, resolved, identity);
            }
            const parent = std.fs.path.dirname(candidate) orelse
                return error.InvalidPath;
            if (std.mem.eql(u8, parent, candidate)) {
                return error.InvalidPath;
            }
            const next = try self.allocator.dupe(u8, parent);
            self.allocator.free(candidate);
            candidate = next;
        }
        return error.InvalidPath;
    }
    fn prospectiveObjectKeyAlloc(
        self: *HostPathIdentityContext,
        candidate: []const u8,
        resolved: []const u8,
        identity: HostObjectIdentity,
    ) ![]u8 {
        const fs = self.fs;
        if (identity.kind != .directory) {
            return error.InvalidPath;
        }
        const suffix = try std.fs.path.relative(
            self.allocator,
            candidate,
            null,
            candidate,
            resolved,
        );
        defer self.allocator.free(suffix);
        const normalized = try self.allocator.dupe(u8, suffix);
        defer self.allocator.free(normalized);
        const separator = std.mem.indexOfScalar(
            u8,
            suffix,
            std.fs.path.sep,
        ) orelse suffix.len;
        if (try directoryNameIsCaseInsensitive(
            fs,
            self.allocator,
            candidate,
            suffix[0..separator],
        )) {
            if (containsNonAscii(normalized)) {
                return error.TransactionRecoveryRequired;
            }
            for (normalized) |*byte| {
                byte.* = std.ascii.toLower(byte.*);
            }
        }
        return self.allocator.print(
            "prospective:{d}:{d}:{s}",
            .{
                identity.device,
                identity.inode,
                normalized,
            },
        );
    }
};

const HostObjectIdentity = struct {
    device: u64,
    mount_id: ?u64 = null,
    inode: std.Io.File.INode,
    kind: std.Io.File.Kind,
    mtime_ns: i96,
    ctime_ns: i96,
};

fn hostObjectIdentitiesEqual(
    left: HostObjectIdentity,
    right: HostObjectIdentity,
) bool {
    return left.device == right.device and
        left.mount_id == right.mount_id and
        left.inode == right.inode and
        left.kind == right.kind and
        left.mtime_ns == right.mtime_ns and
        left.ctime_ns == right.ctime_ns;
}

fn hostObjectIdentity(fs: Fs, path: []const u8) !?HostObjectIdentity {
    if (@import("builtin").os.tag == .windows) return null;
    var file = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(fs.io, path, .{
            .allow_directory = true,
            .follow_symlinks = false,
            .path_only = @import("builtin").os.tag == .linux,
        })
    else
        fs.directory().openFile(fs.io, path, .{
            .allow_directory = true,
            .follow_symlinks = false,
            .path_only = @import("builtin").os.tag == .linux,
        })) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(fs.io);
    const portable_stat = try file.stat(fs.io);
    if (portable_stat.kind == .sym_link) return error.SymLinkLoop;
    const location = try hostFileLocation(file);
    return .{
        .device = location.device,
        .mount_id = location.mount_id,
        .inode = portable_stat.inode,
        .kind = portable_stat.kind,
        .mtime_ns = portable_stat.mtime.nanoseconds,
        .ctime_ns = portable_stat.ctime.nanoseconds,
    };
}

const HostFileLocation = struct {
    device: u64,
    mount_id: ?u64,
};

fn hostFileLocation(file: std.Io.File) !HostFileLocation {
    return switch (@import("builtin").os.tag) {
        .linux => linuxFileLocation(file),
        .windows => unreachable,
        else => posixFileLocation(file),
    };
}

fn linuxFileLocation(file: std.Io.File) !HostFileLocation {
    const linux = std.os.linux;
    for (0..host_syscall_attempts_max) |_| {
        var statx = std.mem.zeroes(linux.Statx);
        const result = linux.statx(
            file.handle,
            "",
            linux.AT.EMPTY_PATH,
            .{ .INO = true, .MNT_ID = true },
            &statx,
        );
        switch (linux.errno(result)) {
            .SUCCESS => return .{
                .device = (@as(u64, statx.dev_major) << 32) |
                    @as(u64, statx.dev_minor),
                .mount_id = if (statx.mask.MNT_ID)
                    statx.mnt_id
                else
                    null,
            },
            .INTR => continue,
            else => return error.TransactionRecoveryRequired,
        }
    }
    return error.TransactionRecoveryRequired;
}

fn posixFileLocation(file: std.Io.File) !HostFileLocation {
    var host_stat: std.posix.Stat = undefined;
    if (std.posix.system.fstat(file.handle, &host_stat) != 0) {
        return error.TransactionRecoveryRequired;
    }
    return .{
        .device = @intCast(host_stat.dev),
        .mount_id = null,
    };
}

test "host object identity collapses hardlinked path aliases" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    if (@import("builtin").os.tag == .windows) {
        return error.SkipZigTest;
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const source_path = try std.fs.path.join(
        allocator,
        &.{ root, "source" },
    );
    defer allocator.free(source_path);
    const alias_path = try std.fs.path.join(
        allocator,
        &.{ root, "alias" },
    );
    defer allocator.free(alias_path);
    try writeTextAtomic(fs, allocator, source_path, "identity\n");
    var root_dir = try std.Io.Dir.openDirAbsolute(fs.io, root, .{});
    defer root_dir.close(fs.io);
    try root_dir.hardLink(
        "source",
        root_dir,
        "alias",
        fs.io,
        .{},
    );
    var identities = HostPathIdentityContext.init(fs, allocator);
    defer identities.deinit();
    const source_key = try identities.objectKeyAlloc(source_path);
    defer allocator.free(source_key);
    const alias_key = try identities.objectKeyAlloc(alias_path);
    defer allocator.free(alias_key);
    try std.testing.expectEqualStrings(source_key, alias_key);
}

fn containsNonAscii(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isAscii(byte)) return true;
    }
    return false;
}

pub const CanonicalPathIndex = struct {
    paths: [][]u8,
    object_keys: [][]u8,
    count: usize = 0,

    pub fn deinit(self: *CanonicalPathIndex, allocator: std.mem.Allocator) void {
        for (self.paths[0..self.count]) |path| allocator.free(path);
        for (self.object_keys[0..self.count]) |key| allocator.free(key);
        allocator.free(self.paths);
        allocator.free(self.object_keys);
        self.* = undefined;
    }

    pub fn items(self: CanonicalPathIndex) []const []u8 {
        return self.paths[0..self.count];
    }

    pub fn append(
        self: *CanonicalPathIndex,
        identities: *HostPathIdentityContext,
        path: []const u8,
    ) !void {
        std.debug.assert(self.count < self.paths.len);
        self.paths[self.count] = try identities.canonicalAlloc(path);
        errdefer identities.allocator.free(self.paths[self.count]);
        self.object_keys[self.count] = try identities.objectKeyAlloc(path);
        self.count += 1;
    }

    pub fn appendDerived(
        self: *CanonicalPathIndex,
        identities: *HostPathIdentityContext,
        resource_path: []const u8,
        suffix: []const u8,
    ) !void {
        const fs = identities.fs;
        std.debug.assert(self.count < self.paths.len);
        const resource_canonical = try identities.canonicalAlloc(
            resource_path,
        );
        defer identities.allocator.free(resource_canonical);
        self.paths[self.count] = try identities.allocator.print(
            "{s}{s}",
            .{ resource_canonical, suffix },
        );
        errdefer identities.allocator.free(self.paths[self.count]);
        const actual_path = try identities.allocator.print(
            "{s}{s}",
            .{ resource_path, suffix },
        );
        defer identities.allocator.free(actual_path);
        self.object_keys[self.count] = if (try hostObjectIdentity(fs, actual_path)) |identity|
            try identities.allocator.print(
                "object:{d}:{d}",
                .{ identity.device, identity.inode },
            )
        else
            try identities.allocator.print(
                "derived:{s}",
                .{self.paths[self.count]},
            );
        self.count += 1;
    }

    pub fn finalize(self: *CanonicalPathIndex) !void {
        std.sort.heap([]u8, self.paths[0..self.count], {}, struct {
            fn lessThan(_: void, left: []u8, right: []u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);
        std.sort.heap([]u8, self.object_keys[0..self.count], {}, struct {
            fn lessThan(_: void, left: []u8, right: []u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);
        if (self.count >= 2) {
            for (self.paths[1..self.count], 1..) |path, index| {
                if (pathsAliasOrOverlapCaseSensitive(
                    self.paths[index - 1],
                    path,
                )) return error.TransactionCorrupt;
            }
            for (self.object_keys[1..self.count], 1..) |key, index| {
                if (std.mem.eql(
                    u8,
                    self.object_keys[index - 1],
                    key,
                )) return error.TransactionCorrupt;
            }
        }
    }

    pub fn objectsIntersect(
        self: CanonicalPathIndex,
        other: CanonicalPathIndex,
    ) bool {
        var left: usize = 0;
        var right: usize = 0;
        while (left < self.count and right < other.count) {
            if (std.mem.eql(
                u8,
                self.object_keys[left],
                other.object_keys[right],
            )) return true;
            if (std.mem.lessThan(
                u8,
                self.object_keys[left],
                other.object_keys[right],
            )) {
                left += 1;
            } else {
                right += 1;
            }
        }
        return false;
    }

    pub fn aliasesCanonical(
        self: CanonicalPathIndex,
        candidate: []const u8,
    ) bool {
        const lower = self.lowerBound(candidate);
        if (lower < self.count and pathIsAtOrBelow(
            candidate,
            self.paths[lower],
        )) return true;
        var ancestor = candidate;
        while (ancestor.len != 0) {
            const parent = std.fs.path.dirname(ancestor) orelse break;
            if (std.mem.eql(u8, parent, ancestor)) break;
            if (self.containsExact(parent)) return true;
            ancestor = parent;
        }
        return false;
    }

    fn containsExact(
        self: CanonicalPathIndex,
        candidate: []const u8,
    ) bool {
        const lower = self.lowerBound(candidate);
        return lower < self.count and
            std.mem.eql(u8, self.paths[lower], candidate);
    }

    fn lowerBound(
        self: CanonicalPathIndex,
        candidate: []const u8,
    ) usize {
        var lower: usize = 0;
        var upper = self.count;
        while (lower < upper) {
            const middle = lower + (upper - lower) / 2;
            if (std.mem.lessThan(
                u8,
                self.paths[middle],
                candidate,
            )) {
                lower = middle + 1;
            } else {
                upper = middle;
            }
        }
        return lower;
    }
};

pub fn pathIsWithinDirectory(
    fs: Fs,
    allocator: std.mem.Allocator,
    directory: []const u8,
    path: []const u8,
) !bool {
    if (pathIsAtOrBelow(directory, path)) return true;
    const canonical_directory = try canonicalProspectivePathAlloc(
        fs,
        allocator,
        directory,
    );
    defer allocator.free(canonical_directory);
    const canonical_path = try canonicalProspectivePathAlloc(
        fs,
        allocator,
        path,
    );
    defer allocator.free(canonical_path);
    if (pathIsAtOrBelow(canonical_directory, canonical_path)) {
        return true;
    }
    return hostPathIsAtOrBelow(fs, allocator, directory, path);
}

fn hostPathIsAtOrBelow(
    fs: Fs,
    allocator: std.mem.Allocator,
    directory: []const u8,
    path: []const u8,
) !bool {
    if (@import("builtin").os.tag == .windows) return false;
    const directory_identity = (try hostObjectIdentity(fs, directory)) orelse
        return false;
    if (directory_identity.kind != .directory) return error.InvalidPath;
    const resolved = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(resolved);
    var candidate = try allocator.dupe(u8, resolved);
    defer allocator.free(candidate);
    while (candidate.len != 0) {
        if (try hostObjectIdentity(fs, candidate)) |identity| {
            if (identity.device == directory_identity.device and
                identity.inode == directory_identity.inode)
            {
                return true;
            }
        }
        const parent = std.fs.path.dirname(candidate) orelse return false;
        if (std.mem.eql(u8, parent, candidate)) return false;
        const next = try allocator.dupe(u8, parent);
        allocator.free(candidate);
        candidate = next;
    }
    return false;
}

pub fn pathIsAtOrBelow(parent: []const u8, candidate: []const u8) bool {
    return std.mem.eql(u8, parent, candidate) or
        (candidate.len > parent.len and
            std.mem.startsWith(u8, candidate, parent) and
            (candidate[parent.len] == '/' or
                candidate[parent.len] == '\\'));
}

pub fn syncDirectoryPath(fs: Fs, path: []const u8) !void {
    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(
            fs.io,
            path,
            .{ .follow_symlinks = false },
        )
    else
        try fs.directory().openDir(
            fs.io,
            path,
            .{ .follow_symlinks = false },
        );
    defer dir.close(fs.io);
    try syncDirectoryHandle(fs, &dir);
}

pub fn syncDirectoryHandle(fs: Fs, dir: *const std.Io.Dir) !void {
    var file = try dir.openFile(fs.io, ".", .{
        .allow_directory = true,
        .follow_symlinks = false,
        .path_only = false,
    });
    defer file.close(fs.io);
    try file.sync(fs.io);
}

pub fn pathsAliasOrOverlap(left: []const u8, right: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(left, right)) return true;
    const shorter = if (left.len < right.len) left else right;
    const longer = if (left.len < right.len) right else left;
    return longer.len > shorter.len and
        std.ascii.startsWithIgnoreCase(longer, shorter) and
        longer[shorter.len] == std.fs.path.sep;
}

pub fn pathsAliasOrOverlapCaseSensitive(
    left: []const u8,
    right: []const u8,
) bool {
    if (std.mem.eql(u8, left, right)) return true;
    const shorter = if (left.len < right.len) left else right;
    const longer = if (left.len < right.len) right else left;
    return longer.len > shorter.len and
        std.mem.startsWith(u8, longer, shorter) and
        longer[shorter.len] == std.fs.path.sep;
}

fn canonicalProspectivePathAlloc(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    if (fs.isPinned() and !std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(allocator, &.{path});
    }
    const resolved = if (std.fs.path.isAbsolute(path))
        try std.fs.path.resolve(allocator, &.{path})
    else blk: {
        const cwd = try fs.directory().realPathFileAlloc(fs.io, ".", allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.resolve(allocator, &.{ cwd, path });
    };
    defer allocator.free(resolved);
    var candidate = try allocator.dupe(u8, resolved);
    defer allocator.free(candidate);
    while (candidate.len != 0) {
        const canonical = fs.directory().realPathFileAlloc(
            fs.io,
            candidate,
            allocator,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const parent = std.fs.path.dirname(candidate) orelse
                    return error.InvalidPath;
                if (std.mem.eql(u8, parent, candidate)) return err;
                const next = try allocator.dupe(u8, parent);
                allocator.free(candidate);
                candidate = next;
                continue;
            },
            else => return err,
        };
        defer allocator.free(canonical);
        if (std.mem.eql(u8, candidate, resolved)) {
            return allocator.dupe(u8, canonical);
        }
        const suffix = try std.fs.path.relative(
            allocator,
            candidate,
            null,
            candidate,
            resolved,
        );
        defer allocator.free(suffix);
        return std.fs.path.join(allocator, &.{ canonical, suffix });
    }
    return error.InvalidPath;
}

pub fn scanJsonlEventStore(
    fs: Fs,
    allocator: std.mem.Allocator,
    logical_ref: []const u8,
    max_bytes: usize,
    visitor: EventRecordVisitor,
    acquire_shared: bool,
) !EventScanSummary {
    var sidecar: ?std.Io.File = null;
    defer if (sidecar) |file| file.close(fs.io);
    _ = try statRegularFileNoSymlink(fs, logical_ref);
    const open_options: std.Io.Dir.OpenFileOptions = .{
        .allow_directory = true,
        .follow_symlinks = false,
        .lock = if (acquire_shared) .shared else .none,
        .lock_nonblocking = acquire_shared,
    };
    var file = (if (std.fs.path.isAbsolute(logical_ref))
        std.Io.Dir.openFileAbsolute(
            fs.io,
            logical_ref,
            open_options,
        )
    else
        fs.directory().openFile(
            fs.io,
            logical_ref,
            open_options,
        )) catch |err| switch (err) {
        error.FileNotFound => {
            if (acquire_shared) {
                sidecar = try acquireEventStoreScanSidecar(
                    fs,
                    allocator,
                    logical_ref,
                );
            }
            return emptyEventScanSummary(allocator, logical_ref, false);
        },
        error.SymLinkLoop => return error.SymlinkComponent,
        error.WouldBlock => return error.EventStoreBusy,
        else => return err,
    };
    defer file.close(fs.io);
    if (acquire_shared) {
        sidecar = try acquireEventStoreScanSidecar(fs, allocator, logical_ref);
    }

    return scanJsonlFile(fs, allocator, logical_ref, max_bytes, visitor, file);
}

fn scanJsonlFile(
    fs: Fs,
    allocator: std.mem.Allocator,
    logical_ref: []const u8,
    max_bytes: usize,
    visitor: EventRecordVisitor,
    file: std.Io.File,
) !EventScanSummary {
    const stat = try file.stat(fs.io);
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    if (stat.size > max_bytes) return error.FileTooBig;

    var reader = file.reader(fs.io, &.{});
    return scanEventReader(allocator, logical_ref, max_bytes, visitor, &reader.interface);
}

fn caseVariantAlloc(
    allocator: std.mem.Allocator,
    name: []const u8,
) !?[]u8 {
    const variant = try allocator.dupe(u8, name);
    errdefer allocator.free(variant);
    for (variant) |*byte| {
        if (std.ascii.isLower(byte.*)) {
            byte.* -= 'a' - 'A';
            return variant;
        }
        if (std.ascii.isUpper(byte.*)) {
            byte.* += 'a' - 'A';
            return variant;
        }
    }
    allocator.free(variant);
    return null;
}

fn nearestExistingPathAlloc(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![:0]u8 {
    if (fs.isPinned() and !std.fs.path.isAbsolute(path)) {
        var candidate = try std.fs.path.resolve(allocator, &.{path});
        defer allocator.free(candidate);
        for (0..path.len + 1) |_| {
            _ = fs.directory().statFile(
                fs.io,
                candidate,
                .{ .follow_symlinks = false },
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    if (std.mem.eql(u8, candidate, ".")) return err;
                    const parent = std.fs.path.dirname(candidate) orelse ".";
                    const next = try allocator.dupe(u8, parent);
                    allocator.free(candidate);
                    candidate = next;
                    continue;
                },
                else => return err,
            };
            return allocator.dupeSentinel(u8, candidate, 0);
        }
        return error.FileNotFound;
    }
    var candidate = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(candidate);
    while (candidate.len != 0) {
        return fs.directory().realPathFileAlloc(
            fs.io,
            candidate,
            allocator,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const parent = std.fs.path.dirname(candidate) orelse return err;
                if (std.mem.eql(u8, parent, candidate)) return err;
                const next = try allocator.dupe(u8, parent);
                allocator.free(candidate);
                candidate = next;
                continue;
            },
            else => return err,
        };
    }
    return error.FileNotFound;
}

const directory_case_direct_entries_max: usize = 64;

const directory_case_inconclusive_entries_max: usize = 64;

const DirectoryCaseCache = struct {
    const Value = union(enum) {
        direct: bool,
        scan_inconclusive,
    };

    const Entry = struct {
        device: u64,
        mount_id: ?u64,
        inode: std.Io.File.INode,
        mtime_ns: i96,
        ctime_ns: i96,
        value: Value,
    };

    direct_entries: [directory_case_direct_entries_max]Entry = undefined,
    direct_count: usize = 0,
    direct_replace_index: usize = 0,
    inconclusive_entries: [directory_case_inconclusive_entries_max]Entry = undefined,
    inconclusive_count: usize = 0,
    inconclusive_replace_index: usize = 0,

    fn get(self: DirectoryCaseCache, identity: HostObjectIdentity) ?Value {
        for (self.direct_entries[0..self.direct_count]) |entry| {
            if (entryMatchesIdentity(entry, identity)) return entry.value;
        }
        for (
            self.inconclusive_entries[0..self.inconclusive_count],
        ) |entry| {
            if (entryMatchesIdentity(entry, identity)) return entry.value;
        }
        return null;
    }

    fn entryMatchesIdentity(
        entry: Entry,
        identity: HostObjectIdentity,
    ) bool {
        return entry.device == identity.device and
            entry.mount_id == identity.mount_id and
            entry.inode == identity.inode and
            entry.mtime_ns == identity.mtime_ns and
            entry.ctime_ns == identity.ctime_ns;
    }

    fn ownerIndex(
        entries: []const Entry,
        identity: HostObjectIdentity,
    ) ?usize {
        for (entries, 0..) |entry, index| {
            if (entry.device == identity.device and
                entry.mount_id == identity.mount_id and
                entry.inode == identity.inode) return index;
        }
        return null;
    }

    fn put(
        self: *DirectoryCaseCache,
        identity: HostObjectIdentity,
        value: Value,
    ) void {
        switch (value) {
            .direct => self.putDirect(identity, value),
            .scan_inconclusive => self.putInconclusive(identity, value),
        }
    }

    fn putDirect(
        self: *DirectoryCaseCache,
        identity: HostObjectIdentity,
        value: Value,
    ) void {
        const entries = self.direct_entries[0..self.direct_count];
        const index = ownerIndex(entries, identity) orelse add: {
            if (self.direct_count < self.direct_entries.len) {
                defer self.direct_count += 1;
                break :add self.direct_count;
            }
            break :add self.direct_replace_index;
        };
        self.direct_entries[index] = makeEntry(identity, value);
        self.direct_replace_index =
            (index + 1) % self.direct_entries.len;
    }

    fn putInconclusive(
        self: *DirectoryCaseCache,
        identity: HostObjectIdentity,
        value: Value,
    ) void {
        for (self.direct_entries[0..self.direct_count]) |entry| {
            if (entryMatchesIdentity(entry, identity)) return;
        }
        const entries =
            self.inconclusive_entries[0..self.inconclusive_count];
        const index = ownerIndex(entries, identity) orelse add: {
            if (self.inconclusive_count <
                self.inconclusive_entries.len)
            {
                defer self.inconclusive_count += 1;
                break :add self.inconclusive_count;
            }
            break :add self.inconclusive_replace_index;
        };
        self.inconclusive_entries[index] = makeEntry(identity, value);
        self.inconclusive_replace_index =
            (index + 1) % self.inconclusive_entries.len;
    }

    fn makeEntry(
        identity: HostObjectIdentity,
        value: Value,
    ) Entry {
        return .{
            .device = identity.device,
            .mount_id = identity.mount_id,
            .inode = identity.inode,
            .mtime_ns = identity.mtime_ns,
            .ctime_ns = identity.ctime_ns,
            .value = value,
        };
    }
};

pub threadlocal var directory_case_cache: DirectoryCaseCache = .{};

test "directory case cache is bounded and identity keyed" {
    var cache: DirectoryCaseCache = .{};
    const first: HostObjectIdentity = .{
        .device = 1,
        .mount_id = 7,
        .inode = 2,
        .kind = .directory,
        .mtime_ns = 3,
        .ctime_ns = 4,
    };
    try std.testing.expect(cache.get(first) == null);
    cache.put(first, .{ .direct = true });
    try std.testing.expect(cache.get(first).?.direct);
    try std.testing.expect(cache.get(.{
        .device = 2,
        .inode = 2,
        .kind = .directory,
        .mtime_ns = 3,
        .ctime_ns = 4,
    }) == null);
    try std.testing.expect(cache.get(.{
        .device = 1,
        .mount_id = 8,
        .inode = 2,
        .kind = .directory,
        .mtime_ns = 3,
        .ctime_ns = 4,
    }) == null);
    var changed = first;
    changed.ctime_ns += 1;
    try std.testing.expect(cache.get(changed) == null);
    cache.put(changed, .scan_inconclusive);
    try std.testing.expectEqual(@as(usize, 1), cache.direct_count);
    try std.testing.expectEqual(@as(usize, 1), cache.inconclusive_count);
    try std.testing.expectEqual(
        DirectoryCaseCache.Value.scan_inconclusive,
        cache.get(changed).?,
    );
    for (0..directory_case_direct_entries_max + 1) |index| {
        cache.put(.{
            .device = 3,
            .inode = @intCast(index),
            .kind = .directory,
            .mtime_ns = 5,
            .ctime_ns = 6,
        }, .{ .direct = false });
    }
    try std.testing.expectEqual(
        directory_case_direct_entries_max,
        cache.direct_count,
    );
}

test "inconclusive case scans enter a saturated cache" {
    var cache: DirectoryCaseCache = .{};
    for (0..directory_case_direct_entries_max) |index| {
        cache.put(.{
            .device = 1,
            .inode = @intCast(index),
            .kind = .directory,
            .mtime_ns = 1,
            .ctime_ns = 1,
        }, .{ .direct = false });
    }
    const inconclusive: HostObjectIdentity = .{
        .device = 2,
        .inode = 1,
        .kind = .directory,
        .mtime_ns = 2,
        .ctime_ns = 2,
    };
    cache.put(inconclusive, .scan_inconclusive);
    try std.testing.expectEqual(
        DirectoryCaseCache.Value.scan_inconclusive,
        cache.get(inconclusive).?,
    );
    try std.testing.expectEqual(
        directory_case_direct_entries_max,
        cache.direct_count,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        cache.inconclusive_count,
    );
    for (0..directory_case_inconclusive_entries_max + 1) |index| {
        cache.put(.{
            .device = 4,
            .inode = @intCast(index),
            .kind = .directory,
            .mtime_ns = 4,
            .ctime_ns = 4,
        }, .scan_inconclusive);
    }
    try std.testing.expectEqual(
        directory_case_inconclusive_entries_max,
        cache.inconclusive_count,
    );
}

pub fn directoryNameIsCaseInsensitive(
    fs: Fs,
    allocator: std.mem.Allocator,
    directory: []const u8,
    witness_name: []const u8,
) !bool {
    for (0..directory_case_probe_attempts_max) |_| {
        return directoryCaseSensitivityAttempt(
            fs,
            allocator,
            directory,
            witness_name,
        ) catch |err| switch (err) {
            error.DirectoryIdentityChanged => continue,
            else => return err,
        };
    }
    return error.TransactionRecoveryRequired;
}

fn directoryCaseSensitivityAttempt(
    fs: Fs,
    allocator: std.mem.Allocator,
    directory: []const u8,
    witness_name: []const u8,
) !bool {
    const canonical = try nearestExistingPathAlloc(fs, allocator, directory);
    defer allocator.free(canonical);
    const identity = try hostObjectIdentity(fs, canonical);
    const cached = if (identity) |value| cache: {
        if (value.kind != .directory) return error.NotDir;
        break :cache directory_case_cache.get(value);
    } else cache: {
        if (@import("builtin").os.tag != .windows) {
            return error.TransactionRecoveryRequired;
        }
        break :cache null;
    };
    if (cached) |value| {
        if (value == .direct) return value.direct;
    }

    var direct: ?bool = if (@import("builtin").os.tag == .windows)
        true
    else
        try targetNameCaseSensitivity(
            fs,
            allocator,
            canonical,
            witness_name,
        );
    var host_error: ?anyerror = null;
    if (direct == null) {
        direct = hostDirectoryCaseSensitivity(fs, canonical) catch |err| value: {
            host_error = err;
            break :value null;
        };
        if (direct == null) {
            if (cached == null or cached.? != .scan_inconclusive) {
                direct = try childNameCaseSensitivity(
                    fs,
                    allocator,
                    canonical,
                );
            }
        }
    }
    if (direct == null) {
        if (host_error) |err| {
            try cacheDirectoryCaseResult(fs, canonical, identity, null);
            return err;
        }
        const before = identity orelse
            return error.TransactionRecoveryRequired;
        if (try directoryCrossesMountBoundary(fs, canonical, before)) {
            return error.TransactionRecoveryRequired;
        }
    }
    const case_insensitive = direct orelse
        try detectAncestorCaseInsensitivity(
            fs,
            allocator,
            canonical,
        );
    try cacheDirectoryCaseResult(fs, canonical, identity, direct);
    return case_insensitive;
}

fn cacheDirectoryCaseResult(
    fs: Fs,
    directory: []const u8,
    identity: ?HostObjectIdentity,
    direct: ?bool,
) !void {
    const before = identity orelse return;
    const refreshed = (try hostObjectIdentity(fs, directory)) orelse
        return error.TransactionRecoveryRequired;
    if (!hostObjectIdentitiesEqual(before, refreshed)) {
        return error.DirectoryIdentityChanged;
    }
    directory_case_cache.put(
        refreshed,
        if (direct) |observed|
            .{ .direct = observed }
        else
            .scan_inconclusive,
    );
}

fn directoryCrossesMountBoundary(
    fs: Fs,
    directory: []const u8,
    identity: HostObjectIdentity,
) !bool {
    const parent = std.fs.path.dirname(directory) orelse return false;
    if (std.mem.eql(u8, parent, directory)) return false;
    const parent_identity = (try hostObjectIdentity(fs, parent)) orelse
        return error.TransactionRecoveryRequired;
    if (parent_identity.kind != .directory) return error.NotDir;
    if (parent_identity.device != identity.device) return true;
    const parent_mount = parent_identity.mount_id orelse return false;
    const directory_mount = identity.mount_id orelse return false;
    return parent_mount != directory_mount;
}

fn hostDirectoryCaseSensitivity(
    fs: Fs,
    directory: []const u8,
) !?bool {
    return switch (@import("builtin").os.tag) {
        .linux => linuxDirectoryCaseSensitivity(fs, directory),
        // std.Io uses case-insensitive Windows object lookup.
        .windows => true,
        else => null,
    };
}

fn linuxDirectoryCaseSensitivity(
    fs: Fs,
    directory: []const u8,
) !?bool {
    const linux = std.os.linux;
    const fs_ioc_getflags = linux.IOCTL.IOR('f', 1, c_long);
    const fs_casefold_fl: c_long = 0x4000_0000;
    var dir = if (std.fs.path.isAbsolute(directory))
        try std.Io.Dir.openDirAbsolute(fs.io, directory, .{
            .iterate = true,
            .follow_symlinks = false,
        })
    else
        try fs.directory().openDir(fs.io, directory, .{
            .iterate = true,
            .follow_symlinks = false,
        });
    defer dir.close(fs.io);
    for (0..host_syscall_attempts_max) |_| {
        var flags: c_long = 0;
        const result = linux.ioctl(
            dir.handle,
            fs_ioc_getflags,
            @intFromPtr(&flags),
        );
        switch (linux.errno(result)) {
            .SUCCESS => return if ((flags & fs_casefold_fl) != 0)
                true
            else
                null,
            .INTR => continue,
            .INVAL, .NOTTY, .OPNOTSUPP, .NOSYS => return null,
            else => return error.TransactionRecoveryRequired,
        }
    }
    return error.TransactionRecoveryRequired;
}

fn detectAncestorCaseInsensitivity(
    fs: Fs,
    allocator: std.mem.Allocator,
    directory: []const u8,
) !bool {
    var canonical = try allocator.dupeSentinel(u8, directory, 0);
    defer allocator.free(canonical);
    while (canonical.len != 0) {
        const parent = std.fs.path.dirname(canonical) orelse return false;
        if (std.mem.eql(u8, parent, canonical)) return false;
        const variant = (try caseVariantAlloc(
            allocator,
            std.fs.path.basename(canonical),
        )) orelse {
            const next = try allocator.dupeSentinel(u8, parent, 0);
            allocator.free(canonical);
            canonical = next;
            continue;
        };
        defer allocator.free(variant);
        const alias = try std.fs.path.join(allocator, &.{ parent, variant });
        defer allocator.free(alias);
        const alias_stat = fs.directory().statFile(
            fs.io,
            alias,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        if (alias_stat.kind != .directory) return false;
        const original_identity = (try hostObjectIdentity(fs, canonical)) orelse
            return error.TransactionRecoveryRequired;
        const alias_identity = (try hostObjectIdentity(fs, alias)) orelse return false;
        // Directory aliases are not regular-file hardlinks. Mount identity keeps
        // separate Linux bind mounts from becoming a case-folding witness.
        if (!caseWitnessObjectsEqual(original_identity, alias_identity)) return false;
        if (!hostObjectIdentitiesEqual(original_identity, alias_identity)) {
            return error.DirectoryIdentityChanged;
        }
        return true;
    }
    return false;
}

fn targetNameCaseSensitivity(
    fs: Fs,
    allocator: std.mem.Allocator,
    directory: []const u8,
    witness_name: []const u8,
) !?bool {
    const attempts_max: usize = 2;
    var dir = if (std.fs.path.isAbsolute(directory))
        try std.Io.Dir.openDirAbsolute(fs.io, directory, .{
            .follow_symlinks = false,
        })
    else
        try fs.directory().openDir(fs.io, directory, .{
            .follow_symlinks = false,
        });
    defer dir.close(fs.io);
    const variant = (try caseVariantAlloc(
        allocator,
        witness_name,
    )) orelse return null;
    defer allocator.free(variant);
    for (0..attempts_max) |_| {
        const first = try targetNameStats(
            fs,
            dir,
            witness_name,
            variant,
        );
        const second = try targetNameStats(
            fs,
            dir,
            witness_name,
            variant,
        );
        if (!first.eql(second)) continue;
        return classifyTargetNameStats(
            fs,
            allocator,
            dir,
            witness_name,
            variant,
            second,
        ) catch |err| switch (err) {
            error.FileNotFound => error.TransactionRecoveryRequired,
            else => err,
        };
    }
    return error.TransactionRecoveryRequired;
}

const TargetNameStats = struct {
    original: ?std.Io.File.Stat,
    alias: ?std.Io.File.Stat,

    fn eql(left: TargetNameStats, right: TargetNameStats) bool {
        return targetNameStatEqual(left.original, right.original) and
            targetNameStatEqual(left.alias, right.alias);
    }
};

fn targetNameStats(
    fs: Fs,
    dir: std.Io.Dir,
    original_name: []const u8,
    alias_name: []const u8,
) !TargetNameStats {
    return .{
        .original = try targetNameStat(fs, dir, original_name),
        .alias = try targetNameStat(fs, dir, alias_name),
    };
}

fn targetNameStatEqual(
    left: ?std.Io.File.Stat,
    right: ?std.Io.File.Stat,
) bool {
    const left_value = left orelse return right == null;
    const right_value = right orelse return false;
    return left_value.inode == right_value.inode and
        left_value.nlink == right_value.nlink and
        left_value.kind == right_value.kind and
        left_value.mtime.nanoseconds == right_value.mtime.nanoseconds and
        left_value.ctime.nanoseconds == right_value.ctime.nanoseconds;
}

fn classifyTargetNameStats(
    fs: Fs,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    witness_name: []const u8,
    variant: []const u8,
    stats: TargetNameStats,
) !?bool {
    if (stats.original) |original| {
        if (original.kind == .sym_link) return null;
    } else {
        const alias = stats.alias orelse return null;
        if (alias.kind == .sym_link) return null;
        return false;
    }
    if (stats.alias) |alias| {
        if (alias.kind == .sym_link) return false;
    } else {
        return false;
    }
    return targetNamesShareDirectoryEntry(fs, allocator, dir, witness_name, variant, stats);
}

pub fn targetNameStat(
    fs: Fs,
    dir: std.Io.Dir,
    name: []const u8,
) !?std.Io.File.Stat {
    return dir.statFile(
        fs.io,
        name,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn targetNamesShareDirectoryEntry(
    fs: Fs,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    original_name: []const u8,
    alias_name: []const u8,
    stats: TargetNameStats,
) !?bool {
    const original_stat = stats.original orelse return error.TransactionRecoveryRequired;
    const alias_stat = stats.alias orelse return error.TransactionRecoveryRequired;
    if (original_stat.inode != alias_stat.inode or original_stat.kind != alias_stat.kind) {
        return false;
    }
    if (!targetNameStatEqual(original_stat, alias_stat)) return null;
    const original = try dir.realPathFileAlloc(fs.io, original_name, allocator);
    defer allocator.free(original);
    const alias = try dir.realPathFileAlloc(fs.io, alias_name, allocator);
    defer allocator.free(alias);
    if (std.mem.eql(u8, original, alias)) return true;
    if (@import("builtin").os.tag != .linux) {
        return caseNamesAreOneDirectoryEntry(fs, dir, original_name);
    }
    // Linux realpath preserves lookup spelling on case-folding mounts. A name
    // mismatch is inconclusive; identity distinguishes objects, not hardlinks.
    const original_identity = (try hostObjectIdentity(fs, original)) orelse
        return error.TransactionRecoveryRequired;
    const alias_identity = (try hostObjectIdentity(fs, alias)) orelse
        return error.TransactionRecoveryRequired;
    if (!caseWitnessObjectsEqual(original_identity, alias_identity)) return false;
    if (!hostObjectIdentitiesEqual(original_identity, alias_identity)) return null;
    if (original_identity.inode != original_stat.inode or
        original_identity.ctime_ns != original_stat.ctime.nanoseconds or
        original_identity.mtime_ns != original_stat.mtime.nanoseconds) return null;
    if (original_stat.kind == .directory or original_stat.nlink == 1) return true;
    return caseNamesAreOneDirectoryEntry(fs, dir, original_name);
}

fn caseWitnessObjectsEqual(left: HostObjectIdentity, right: HostObjectIdentity) bool {
    return left.device == right.device and left.mount_id == right.mount_id and
        left.inode == right.inode and left.kind == right.kind;
}

fn caseNamesAreOneDirectoryEntry(fs: Fs, dir: std.Io.Dir, name: []const u8) !?bool {
    const entries_max: usize = 1024;
    var listing = try dir.openDir(fs.io, ".", .{ .iterate = true });
    defer listing.close(fs.io);
    var iter = listing.iterate();
    var matches: usize = 0;
    for (0..entries_max) |_| {
        const entry = (try iter.next(fs.io)) orelse return if (matches == 1) true else null;
        if (!std.ascii.eqlIgnoreCase(entry.name, name)) continue;
        matches += 1;
        if (matches > 1) return false;
    }
    return null;
}

fn childNameCaseSensitivity(
    fs: Fs,
    allocator: std.mem.Allocator,
    directory: []const u8,
) !?bool {
    const entries_max: usize = 1024;
    var dir = if (std.fs.path.isAbsolute(directory))
        try std.Io.Dir.openDirAbsolute(fs.io, directory, .{
            .iterate = true,
            .follow_symlinks = false,
        })
    else
        try fs.directory().openDir(fs.io, directory, .{
            .iterate = true,
            .follow_symlinks = false,
        });
    defer dir.close(fs.io);
    var entries: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(fs.io)) |entry| {
        entries += 1;
        if (entries > entries_max) return null;
        if (try entryNameCaseSensitivity(fs, allocator, dir, entry.name)) |sensitivity| {
            return sensitivity;
        }
    }
    return null;
}

fn entryNameCaseSensitivity(
    fs: Fs,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    entry_name: []const u8,
) !?bool {
    const variant = (try caseVariantAlloc(allocator, entry_name)) orelse return null;
    defer allocator.free(variant);
    const stats = try targetNameStats(fs, dir, entry_name, variant);
    if (stats.original == null) return null;
    if (stats.alias == null) return existingCaseWitness(fs, dir, entry_name);
    return classifyTargetNameStats(
        fs,
        allocator,
        dir,
        entry_name,
        variant,
        stats,
    ) catch |err| switch (err) {
        error.FileNotFound => existingCaseWitness(fs, dir, entry_name),
        else => err,
    };
}

fn existingCaseWitness(fs: Fs, dir: std.Io.Dir, entry_name: []const u8) !?bool {
    const witness = dir.statFile(
        fs.io,
        entry_name,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return if (witness.kind == .sym_link) null else false;
}

fn eventStoreIdentityBasenameAlloc(
    fs: Fs,
    allocator: std.mem.Allocator,
    store_path: []const u8,
) ![:0]u8 {
    const identity_path = if (fs.isPinned() and !std.fs.path.isAbsolute(store_path))
        try allocator.dupeSentinel(u8, store_path, 0)
    else
        fs.directory().realPathFileAlloc(
            fs.io,
            store_path,
            allocator,
        ) catch |err| switch (err) {
            error.FileNotFound => try allocator.dupeSentinel(u8, store_path, 0),
            else => return err,
        };
    defer allocator.free(identity_path);
    const basename = std.fs.path.basename(identity_path);
    const identity = try allocator.dupeSentinel(u8, basename, 0);
    errdefer allocator.free(identity);
    const parent = std.fs.path.dirname(identity_path) orelse ".";
    if (try directoryNameIsCaseInsensitive(
        fs,
        allocator,
        parent,
        basename,
    )) {
        for (identity[0..basename.len]) |*byte| {
            byte.* = std.ascii.toLower(byte.*);
        }
    }
    return identity;
}

pub fn eventStoreLockPathAlloc(
    fs: Fs,
    allocator: std.mem.Allocator,
    store_path: []const u8,
) ![]u8 {
    try rejectEventStoreControlNamespace(store_path);
    const identity_basename = try eventStoreIdentityBasenameAlloc(
        fs,
        allocator,
        store_path,
    );
    defer allocator.free(identity_basename);
    var digest: [EventHash.digest_length]u8 = undefined;
    EventHash.hash(std.fs.path.basename(identity_basename), &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    const file_name = try allocator.print(
        "{s}.lock",
        .{&encoded},
    );
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{
        std.fs.path.dirname(store_path) orelse ".",
        event_store_lock_dir_name,
        file_name,
    });
}

pub fn casLockPathAlloc(allocator: std.mem.Allocator, store_path: []const u8) ![]u8 {
    try rejectCasControlTargetPath(store_path);
    return allocator.print("{s}.cas.lock", .{store_path});
}

pub fn rejectCasControlTargetPath(store_path: []const u8) !void {
    var components = std.mem.tokenizeAny(u8, store_path, "/\\");
    while (components.next()) |component| {
        if (endsWithAsciiIgnoreCase(component, ".cas.lock") or
            endsWithAsciiIgnoreCase(component, ".cas.lock.advisory"))
        {
            return error.ReservedCasControlPath;
        }
    }
}

fn endsWithAsciiIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

pub fn casAdvisoryPathAlloc(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) ![]u8 {
    const cas_path = try casLockPathAlloc(allocator, store_path);
    defer allocator.free(cas_path);
    return allocator.print(
        "{s}.advisory",
        .{cas_path},
    );
}

pub fn acquireCasAdvisoryLock(
    fs: Fs,
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !std.Io.File {
    return acquireCasAdvisoryLockObserved(
        fs,
        allocator,
        store_path,
        null,
    );
}

pub fn acquireCasAdvisoryLockObserved(
    fs: Fs,
    allocator: std.mem.Allocator,
    store_path: []const u8,
    storage_mutated: ?*bool,
) !std.Io.File {
    const advisory_path = try casAdvisoryPathAlloc(
        allocator,
        store_path,
    );
    defer allocator.free(advisory_path);
    var created = false;
    const lock = openEventStoreSidecarExclusiveObserved(
        fs,
        advisory_path,
        &created,
    ) catch |err| switch (err) {
        error.WouldBlock => return error.LockBusy,
        else => return err,
    };
    if (created) {
        if (storage_mutated) |mutated| mutated.* = true;
    }
    return lock;
}

pub const CasReadLockPair = struct {
    fs: Fs,
    files: [2]std.Io.File = undefined,
    count: u2 = 0,

    pub fn deinit(self: *CasReadLockPair) void {
        const fs = self.fs;
        for (self.files[0..self.count]) |file| file.close(fs.io);
        self.* = undefined;
    }
};

pub fn acquireCasReadLockPair(
    fs: Fs,
    allocator: std.mem.Allocator,
    left_path: []const u8,
    right_path: []const u8,
) !CasReadLockPair {
    const left_first = std.mem.lessThan(u8, left_path, right_path);
    const paths = if (left_first)
        [2][]const u8{ left_path, right_path }
    else
        [2][]const u8{ right_path, left_path };
    var result = CasReadLockPair{ .fs = fs };
    errdefer result.deinit();
    for (paths, 0..) |path, index| {
        if (index == 1 and std.mem.eql(u8, paths[0], path)) break;
        result.files[result.count] =
            (try openCasAdvisorySharedIfExists(fs, allocator, path)) orelse
            continue;
        result.count += 1;
    }
    return result;
}

pub fn casAdvisoryLockExists(
    fs: Fs,
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !bool {
    const advisory_path = try casAdvisoryPathAlloc(allocator, store_path);
    defer allocator.free(advisory_path);
    return (try statRegularFileNoSymlink(fs, advisory_path)) != null;
}

fn openCasAdvisorySharedIfExists(
    fs: Fs,
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !?std.Io.File {
    const advisory_path = try casAdvisoryPathAlloc(allocator, store_path);
    defer allocator.free(advisory_path);
    _ = (try statRegularFileNoSymlink(fs, advisory_path)) orelse return null;
    return try openEventStoreSidecarSharedExisting(fs, advisory_path);
}

pub fn acquireTransactionJournalLock(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    storage_mutated: ?*bool,
) !std.Io.File {
    const path = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, ".journal.advisory" },
    );
    defer allocator.free(path);
    var created = false;
    const lock = openEventStoreSidecarExclusiveObserved(
        fs,
        path,
        &created,
    ) catch |err| switch (err) {
        error.WouldBlock => return error.LockBusy,
        else => return err,
    };
    if (created) {
        if (storage_mutated) |mutated| mutated.* = true;
    }
    return lock;
}

pub fn acquireTransactionRecoveryLock(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    storage_mutated: ?*bool,
) !std.Io.File {
    const path = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, ".recovery.advisory" },
    );
    defer allocator.free(path);
    var created = false;
    const lock = openEventStoreSidecarExclusiveObserved(
        fs,
        path,
        &created,
    ) catch |err| switch (err) {
        error.WouldBlock => return error.LockBusy,
        else => return err,
    };
    if (created) {
        if (storage_mutated) |mutated| mutated.* = true;
    }
    return lock;
}

pub fn fileExists(fs: Fs, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(fs.io, path, .{}) catch return false;
        return true;
    }
    fs.directory().access(fs.io, path, .{}) catch return false;
    return true;
}

pub fn fileSize(fs: Fs, path: []const u8) !u64 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(fs.io, path, .{})
    else
        try fs.directory().openFile(fs.io, path, .{});
    defer file.close(fs.io);

    const stat = try file.stat(fs.io);
    return stat.size;
}

pub fn readFileAlloc(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(fs.io, path, .{})
    else
        try fs.directory().openFile(fs.io, path, .{});
    defer file.close(fs.io);

    var reader = file.reader(fs.io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

pub fn ensureParentPath(fs: Fs, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;

    if (std.fs.path.isAbsolute(parent)) {
        const rel = std.mem.trim(u8, parent, "/");
        if (rel.len == 0) return;
        var root = try std.Io.Dir.openDirAbsolute(fs.io, "/", .{});
        defer root.close(fs.io);
        try root.createDirPath(fs.io, rel);
        return;
    }

    try fs.directory().createDirPath(fs.io, parent);
}

pub fn rejectSymlinkComponents(fs: Fs, path: []const u8) !void {
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        const stat = fs.directory().statFile(
            fs.io,
            component.path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkComponent;
    }
}

pub fn ensureDirectoryPathNoSymlinks(fs: Fs, path: []const u8) !void {
    var storage_mutated = false;
    return ensureDirectoryPathNoSymlinksObserved(
        fs,
        path,
        &storage_mutated,
    );
}

pub fn ensureDirectoryPathNoSymlinksObserved(
    fs: Fs,
    path: []const u8,
    storage_mutated: *bool,
) !void {
    if (path.len == 0 or std.mem.eql(u8, path, ".")) return;

    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        const stat = fs.directory().statFile(
            fs.io,
            component.path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => {
                var created = true;
                fs.directory().createDir(
                    fs.io,
                    component.path,
                    .default_dir,
                ) catch |create_error| switch (create_error) {
                    error.PathAlreadyExists => created = false,
                    else => return create_error,
                };
                if (created) storage_mutated.* = true;
                const created_stat = try fs.directory().statFile(
                    fs.io,
                    component.path,
                    .{ .follow_symlinks = false },
                );
                if (created_stat.kind == .sym_link) return error.SymlinkComponent;
                if (created_stat.kind != .directory) return error.NotDir;
                try syncDirectoryPath(fs, component.path);
                try syncDirectoryPath(
                    fs,
                    std.fs.path.dirname(component.path) orelse ".",
                );
                continue;
            },
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .directory) return error.NotDir;
    }
}

pub fn ensurePrivateDirectoryPathNoSymlinks(fs: Fs, path: []const u8) !void {
    try ensureDirectoryPathNoSymlinks(fs, path);
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return;
    try fs.directory().setFilePermissions(
        fs.io,
        path,
        std.Io.File.Permissions.fromMode(0o700),
        .{ .follow_symlinks = false },
    );
    try validatePrivateDirectoryPathNoSymlinks(fs, path);
}

pub fn validatePrivateDirectoryPathNoSymlinks(fs: Fs, path: []const u8) !void {
    const stat = try fs.directory().statFile(
        fs.io,
        path,
        .{ .follow_symlinks = false },
    );
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .directory) return error.NotDir;
    if (@hasDecl(std.Io.File.Permissions, "toMode") and
        stat.permissions.toMode() & 0o077 != 0)
    {
        return error.InsecurePrivateDirectory;
    }
}

pub fn statRegularFileNoSymlink(fs: Fs, path: []const u8) !?std.Io.File.Stat {
    const stat = fs.directory().statFile(
        fs.io,
        path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    return stat;
}

pub fn readRegularFileNoSymlink(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    const stat = (try statRegularFileNoSymlink(fs, path)) orelse
        return error.FileNotFound;
    if (stat.size > max_bytes) return error.FileTooBig;

    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(
            fs.io,
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        )
    else
        try fs.directory().openFile(
            fs.io,
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        );
    defer file.close(fs.io);

    var reader = file.reader(fs.io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes + 1));
}

pub fn freeStringList(allocator: std.mem.Allocator, list: []const []u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

pub fn listSortedRegularFilesNoSymlink(
    fs: Fs,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    max_files: usize,
    max_file_bytes: usize,
) ![][]u8 {
    const dir_stat = try fs.directory().statFile(
        fs.io,
        dir_path,
        .{ .follow_symlinks = false },
    );
    if (dir_stat.kind == .sym_link) return error.SymlinkComponent;
    if (dir_stat.kind != .directory) return error.NotDir;

    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.Io.Dir.openDirAbsolute(
            fs.io,
            dir_path,
            .{ .iterate = true, .follow_symlinks = false },
        )
    else
        try fs.directory().openDir(
            fs.io,
            dir_path,
            .{ .iterate = true, .follow_symlinks = false },
        );
    defer dir.close(fs.io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(fs.io)) |entry| {
        if (entry.kind == .sym_link) return error.SymlinkComponent;
        if (entry.kind != .file) continue;
        if (names.items.len >= max_files) return error.TooManyFiles;

        const entry_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(entry_path);
        const stat = try fs.directory().statFile(
            fs.io,
            entry_path,
            .{ .follow_symlinks = false },
        );
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .file) continue;
        if (stat.size > max_file_bytes) return error.FileTooBig;

        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try names.append(allocator, name);
    }
    std.sort.heap([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names.toOwnedSlice(allocator);
}

fn filePermissionsFromMode(mode: ?u32) std.Io.File.Permissions {
    const Permissions = std.Io.File.Permissions;
    const requested = mode orelse return .default_file;
    if (@hasDecl(Permissions, "fromMode")) {
        return Permissions.fromMode(@as(std.posix.mode_t, @intCast(requested)));
    }
    return .default_file;
}

pub fn writeTextCreateNew(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    options: CreateNewOptions,
) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    if (parent.len == 0 or
        base.len == 0 or
        std.mem.eql(u8, base, ".") or
        std.mem.eql(u8, base, ".."))
    {
        return error.InvalidPath;
    }
    if (options.reject_symlinks) {
        try ensureDirectoryPathNoSymlinks(fs, parent);
        const existing_stat = fs.directory().statFile(
            fs.io,
            path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing_stat) |stat| {
            if (stat.kind == .sym_link) return error.SymlinkComponent;
        }
    } else {
        try ensureParentPath(fs, path);
    }

    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(fs.io, parent, .{ .follow_symlinks = false })
    else
        try fs.directory().openDir(fs.io, parent, .{ .follow_symlinks = false });
    defer dir.close(fs.io);

    var file = try dir.createFile(fs.io, base, .{
        .exclusive = true,
        .read = true,
        .truncate = false,
        .permissions = filePermissionsFromMode(options.file_mode),
    });
    var close_file = true;
    errdefer {
        if (close_file) file.close(fs.io);
        deleteFileAfterFailure(fs, dir, base);
    }
    try file.writeStreamingAll(fs.io, text);
    if (options.sync) try file.sync(fs.io);
    file.close(fs.io);
    close_file = false;
    _ = allocator;
}

pub fn writeTextCreateNewAtomic(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    options: CreateNewOptions,
) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    if (parent.len == 0 or base.len == 0 or
        std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, ".."))
    {
        return error.InvalidPath;
    }
    if (options.reject_symlinks) {
        try ensureDirectoryPathNoSymlinks(fs, parent);
        const existing_stat = fs.directory().statFile(
            fs.io,
            path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing_stat) |stat| {
            if (stat.kind == .sym_link) return error.SymlinkComponent;
        }
    } else {
        try ensureParentPath(fs, path);
    }

    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(fs.io, parent, .{ .follow_symlinks = false })
    else
        try fs.directory().openDir(fs.io, parent, .{ .follow_symlinks = false });
    defer dir.close(fs.io);

    try publicationResult(fs.io, staged_file.publishCreateNew(fs.io, dir, dir, base, &.{text}, .{
        .permissions = filePermissionsFromMode(options.file_mode),
        .durability = if (options.sync) .file_synced else .atomic_visibility,
    }));
    _ = allocator;
}

pub fn writeTextAtomic(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
) !void {
    return writeTextAtomicMode(fs, allocator, path, text, null);
}

fn writeTextAtomicMode(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    file_mode: ?u32,
) !void {
    const base = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse ".";
    try ensureDirectoryPathNoSymlinks(fs, parent);
    var dir = try fs.directory().openDir(fs.io, parent, .{ .follow_symlinks = false });
    defer dir.close(fs.io);
    try publicationResult(fs.io, staged_file.publishReplacement(fs.io, dir, dir, base, &.{text}, .{
        .permissions = filePermissionsFromMode(file_mode),
    }));
    _ = allocator;
}

// Preserve path-wrapper errors without treating an error as proof of no change.
// Transaction callers retain their journal and recovery responsibilities.
fn publicationResult(io: std.Io, outcome: staged_file.PublicationOutcome) !void {
    switch (outcome) {
        .complete => {},
        .not_published, .publication_unknown => |failure| {
            if (failure.cleanup) |cleanup| fs_authority.warn(
                io,
                "rollback file removal failed for {s}: {s}; inspect and remove the leftover file",
                .{ cleanup.stage_name, @errorName(cleanup.cause) },
            );
            return failure.cause;
        },
        .published_unsynced => |err| return err,
    }
}

pub fn deleteFileAfterFailure(fs: Fs, dir: std.Io.Dir, path: []const u8) void {
    dir.deleteFile(fs.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => fs_authority.warn(
            fs.io,
            "rollback file removal failed for {s}: {s}; inspect and remove the leftover file",
            .{ path, @errorName(err) },
        ),
    };
}

fn addCopiedBytesWithinLimit(
    copied_bytes: usize,
    read_bytes: usize,
    max_existing_bytes: usize,
) !usize {
    const next = std.math.add(
        usize,
        copied_bytes,
        read_bytes,
    ) catch return error.StreamTooLong;
    if (next > max_existing_bytes) return error.StreamTooLong;
    return next;
}

pub fn appendLineAtomic(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    line: []const u8,
    max_existing_bytes: usize,
) !void {
    const receipt = try appendLineAtomicPrepared(
        fs,
        allocator,
        path,
        line,
        max_existing_bytes,
        null,
    );
    std.debug.assert(receipt == null);
}

pub fn appendLineAtomicPrepared(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    line: []const u8,
    max_existing_bytes: usize,
    before: ?EventScanSummary,
) !?EventAppendReceipt {
    const parent = try validatedFileParent(path);
    const base = std.fs.path.basename(path);
    try ensureDirectoryPathNoSymlinks(fs, parent);

    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(
            fs.io,
            parent,
            .{ .follow_symlinks = false },
        )
    else
        try fs.directory().openDir(
            fs.io,
            parent,
            .{ .follow_symlinks = false },
        );
    defer dir.close(fs.io);

    const source = try openAtomicAppendSource(fs, dir, base, max_existing_bytes);
    defer if (source) |file| file.close(fs.io);

    const tmp_name = try allocator.print(
        ".{s}.{d}.tmp",
        .{ base, std.Io.Clock.awake.now(fs.io).nanoseconds },
    );
    defer allocator.free(tmp_name);
    var destination = try dir.createFile(fs.io, tmp_name, .{
        .exclusive = true,
        .read = true,
        .truncate = true,
    });
    var destination_open = true;
    errdefer if (destination_open) destination.close(fs.io);
    errdefer deleteFileAfterFailure(fs, dir, tmp_name);

    const last_byte = try copyAppendSource(fs, source, destination, max_existing_bytes);
    if (last_byte != null and last_byte.? != '\n') {
        try destination.writeStreamingAll(fs.io, "\n");
    }
    try destination.writeStreamingAll(fs.io, line);
    try destination.writeStreamingAll(fs.io, "\n");
    var receipt = try prepareAppendedReceipt(
        fs,
        allocator,
        path,
        max_existing_bytes,
        before,
        destination,
    );
    errdefer if (receipt) |*value| value.deinit(allocator);
    try destination.sync(fs.io);
    destination.close(fs.io);
    destination_open = false;
    try dir.rename(tmp_name, dir, base, fs.io);
    return receipt;
}

fn openAtomicAppendSource(
    fs: Fs,
    dir: std.Io.Dir,
    base: []const u8,
    max_existing_bytes: usize,
) !?std.Io.File {
    var source: ?std.Io.File = dir.openFile(fs.io, base, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    errdefer if (source) |file| file.close(fs.io);
    if (source) |*file| {
        const stat = try file.stat(fs.io);
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .file) return error.NotFile;
        if (stat.size > max_existing_bytes) return error.StreamTooLong;
    }

    return source;
}

fn prepareAppendedReceipt(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
    before: ?EventScanSummary,
    staged: std.Io.File,
) !?EventAppendReceipt {
    const snapshot = before orelse return null;
    var ignored: u8 = 0;
    const visitor: EventRecordVisitor = .{ .context = &ignored, .visitFn = ignoreEventRecord };
    var after = try scanJsonlFile(fs, allocator, path, max_bytes, visitor, staged);
    defer after.deinit(allocator);
    return try eventAppendReceipt(allocator, snapshot, after);
}

fn validatedFileParent(path: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    if (parent.len == 0 or base.len == 0 or
        std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, ".."))
    {
        return error.InvalidPath;
    }
    return parent;
}

fn copyAppendSource(
    fs: Fs,
    source: ?std.Io.File,
    destination: std.Io.File,
    max_existing_bytes: usize,
) !?u8 {
    var last_byte: ?u8 = null;
    var copied_bytes: usize = 0;
    if (source) |file| {
        var reader = file.reader(fs.io, &.{});
        var buffer: [jsonl_core.chunk_size]u8 = undefined;
        while (copied_bytes <= max_existing_bytes) {
            const read = try reader.interface.readSliceShort(&buffer);
            if (read == 0) break;
            copied_bytes = try addCopiedBytesWithinLimit(
                copied_bytes,
                read,
                max_existing_bytes,
            );
            try destination.writeStreamingAll(fs.io, buffer[0..read]);
            last_byte = buffer[read - 1];
        }
    }
    return last_byte;
}

pub fn appendLineStreaming(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    line: []const u8,
    options: AppendLineOptions,
) !void {
    const parent = try validatedFileParent(path);
    const base = std.fs.path.basename(path);
    if (options.reject_symlinks) {
        try ensureDirectoryPathNoSymlinks(fs, parent);
        const existing_stat = fs.directory().statFile(
            fs.io,
            path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing_stat) |stat| {
            if (stat.kind == .sym_link) return error.SymlinkComponent;
            if (stat.kind != .file) return error.NotFile;
        }
    } else {
        try ensureParentPath(fs, path);
    }

    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(fs.io, parent, .{ .follow_symlinks = false })
    else
        try fs.directory().openDir(fs.io, parent, .{ .follow_symlinks = false });
    defer dir.close(fs.io);

    var file = try openAppendFile(fs, dir, base, options.file_mode);
    defer file.close(fs.io);

    const stat = try file.stat(fs.io);
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    var offset = stat.size;
    if (stat.size > 0) {
        var last: [1]u8 = undefined;
        const read = try file.readPositionalAll(fs.io, &last, stat.size - 1);
        if (read == 1 and last[0] != '\n') {
            try file.writePositionalAll(fs.io, "\n", offset);
            offset += 1;
        }
    }
    try file.writePositionalAll(fs.io, line, offset);
    try file.writePositionalAll(fs.io, "\n", offset + line.len);
    if (options.sync) try file.sync(fs.io);
    _ = allocator;
}

fn openAppendFile(
    fs: Fs,
    dir: std.Io.Dir,
    base: []const u8,
    file_mode: ?u32,
) !std.Io.File {
    return dir.openFile(fs.io, base, .{
        .mode = .read_write,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => dir.createFile(fs.io, base, .{
            .exclusive = true,
            .read = true,
            .truncate = false,
            .permissions = filePermissionsFromMode(file_mode),
        }) catch |create_err| switch (create_err) {
            error.PathAlreadyExists => try dir.openFile(fs.io, base, .{
                .mode = .read_write,
                .allow_directory = false,
                .follow_symlinks = false,
            }),
            else => return create_err,
        },
        else => return err,
    };
}

pub fn validateJsonl(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) !JsonlValidation {
    const data = readFileAlloc(fs, allocator, path, max_bytes) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(data);
    return validateJsonlBytes(allocator, data);
}

pub const LockFile = struct {
    fs: Fs,
    path: []u8,

    pub fn releaseChecked(
        self: *LockFile,
        allocator: std.mem.Allocator,
    ) !void {
        const fs = self.fs;
        if (std.fs.path.isAbsolute(self.path)) {
            try std.Io.Dir.deleteFileAbsolute(fs.io, self.path);
        } else {
            try fs.directory().deleteFile(fs.io, self.path);
        }
        allocator.free(self.path);
        self.* = .{ .path = &.{}, .fs = self.fs };
    }

    pub fn release(self: *LockFile, allocator: std.mem.Allocator) void {
        const fs = self.fs;
        self.releaseChecked(allocator) catch |err| {
            // Release often follows publication: cleanup failure cannot turn a
            // committed write into a reported failure that invites a retry.
            fs_authority.warn(
                fs.io,
                "lock release failed for {s}: {s}; inspect and remove stale lock",
                .{ self.path, @errorName(err) },
            );
            allocator.free(self.path);
            self.* = .{ .path = &.{}, .fs = self.fs };
        };
    }
};

pub const EventStoreExclusiveLock = struct {
    fs: Fs,
    allocator: std.mem.Allocator,
    compatibility: LockFile,
    sidecar: std.Io.File,
    data: ?std.Io.File,

    pub fn release(self: *EventStoreExclusiveLock) void {
        const fs = self.fs;
        if (self.data) |file| file.close(fs.io);
        self.sidecar.close(fs.io);
        self.compatibility.release(self.allocator);
        self.* = undefined;
    }
};

pub fn acquireEventStoreExclusiveLock(
    fs: Fs,
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !EventStoreExclusiveLock {
    var compatibility = acquireLock(fs, allocator, store_path) catch |err| switch (err) {
        error.PathAlreadyExists => return error.EventStoreBusy,
        else => return err,
    };
    errdefer compatibility.release(allocator);
    const lock_path = try eventStoreLockPathAlloc(fs, allocator, store_path);
    defer allocator.free(lock_path);
    try ensureParentPath(fs, lock_path);
    var sidecar = try openEventStoreSidecarExclusive(fs, lock_path);
    errdefer sidecar.close(fs.io);
    const data = try openEventStoreDataExclusive(fs, store_path);
    errdefer if (data) |file| file.close(fs.io);
    return .{
        .fs = fs,
        .allocator = allocator,
        .compatibility = compatibility,
        .sidecar = sidecar,
        .data = data,
    };
}

fn openEventStoreSidecarExclusive(fs: Fs, path: []const u8) !std.Io.File {
    var created = false;
    return openEventStoreSidecarExclusiveObserved(fs, path, &created);
}

fn openEventStoreSidecarExclusiveObserved(
    fs: Fs,
    path: []const u8,
    created: *bool,
) !std.Io.File {
    var attempt: u8 = 0;
    while (attempt < 4) : (attempt += 1) {
        const file = (if (std.fs.path.isAbsolute(path))
            std.Io.Dir.createFileAbsolute(fs.io, path, .{
                .exclusive = true,
                .read = true,
                .truncate = false,
                .lock = .exclusive,
                .lock_nonblocking = true,
            })
        else
            fs.directory().createFile(fs.io, path, .{
                .exclusive = true,
                .read = true,
                .truncate = false,
                .lock = .exclusive,
                .lock_nonblocking = true,
            })) catch |create_err| switch (create_err) {
            error.PathAlreadyExists => {
                _ = (try statRegularFileNoSymlink(fs, path)) orelse continue;
                return (if (std.fs.path.isAbsolute(path))
                    std.Io.Dir.openFileAbsolute(fs.io, path, .{
                        .allow_directory = false,
                        .follow_symlinks = false,
                        .lock = .exclusive,
                        .lock_nonblocking = true,
                    })
                else
                    fs.directory().openFile(fs.io, path, .{
                        .allow_directory = false,
                        .follow_symlinks = false,
                        .lock = .exclusive,
                        .lock_nonblocking = true,
                    })) catch |open_err| switch (open_err) {
                    error.FileNotFound => continue,
                    error.SymLinkLoop => return error.SymlinkComponent,
                    else => return open_err,
                };
            },
            else => return create_err,
        };
        created.* = true;
        return file;
    }
    return error.FileNotFound;
}

fn openEventStoreSidecarSharedExisting(fs: Fs, path: []const u8) !std.Io.File {
    var file = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(fs.io, path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = .shared,
            .lock_nonblocking = true,
        })
    else
        fs.directory().openFile(fs.io, path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = .shared,
            .lock_nonblocking = true,
        })) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCasAdvisoryLock,
        error.SymLinkLoop => return error.SymlinkComponent,
        error.WouldBlock => return error.EventStoreBusy,
        else => return err,
    };
    errdefer file.close(fs.io);
    const stat = try file.stat(fs.io);
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    return file;
}

fn openEventStoreDataExclusive(fs: Fs, store_path: []const u8) !?std.Io.File {
    _ = (try statRegularFileNoSymlink(fs, store_path)) orelse return null;
    // Windows byte-range locks conflict with the exclusive session's own
    // reopened scan and append handles. The stable sidecar remains the
    // canonical same-store exclusion witness on that platform.
    if (@import("builtin").os.tag == .windows) return null;
    var file = (if (std.fs.path.isAbsolute(store_path))
        std.Io.Dir.openFileAbsolute(fs.io, store_path, .{
            .allow_directory = true,
            .follow_symlinks = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        })
    else
        fs.directory().openFile(fs.io, store_path, .{
            .allow_directory = true,
            .follow_symlinks = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        })) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop => return error.SymlinkComponent,
        else => return err,
    };
    errdefer file.close(fs.io);
    const stat = try file.stat(fs.io);
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    return file;
}

fn acquireEventStoreScanSidecar(
    fs: Fs,
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !?std.Io.File {
    const path = try eventStoreLockPathAlloc(fs, allocator, store_path);
    defer allocator.free(path);
    _ = (try statRegularFileNoSymlink(fs, path)) orelse return null;
    var file = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(fs.io, path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = .shared,
            .lock_nonblocking = true,
        })
    else
        fs.directory().openFile(fs.io, path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = .shared,
            .lock_nonblocking = true,
        })) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop => return error.SymlinkComponent,
        error.WouldBlock => return error.EventStoreBusy,
        else => return err,
    };
    errdefer file.close(fs.io);
    const stat = try file.stat(fs.io);
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    return file;
}

pub fn acquireLock(fs: Fs, allocator: std.mem.Allocator, store_path: []const u8) !LockFile {
    const path = try lockPathAlloc(allocator, store_path);
    errdefer allocator.free(path);
    try ensureParentPath(fs, path);
    var file = try fs.directory().createFile(fs.io, path, .{
        .exclusive = true,
        .read = true,
        .truncate = false,
    });
    file.close(fs.io);
    return .{ .path = path, .fs = fs };
}

pub fn acquireAbsoluteExclusiveLock(
    fs: Fs,
    allocator: std.mem.Allocator,
    absolute_path: []const u8,
) !LockFile {
    if (!std.fs.path.isAbsolute(absolute_path)) return error.NotAbsolute;
    const path = try allocator.dupe(u8, absolute_path);
    errdefer allocator.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try ensureDirectoryPathNoSymlinks(fs, parent);
    const existing_stat = fs.directory().statFile(
        fs.io,
        path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing_stat) |stat| {
        if (stat.kind == .sym_link) return error.SymlinkComponent;
    }
    var file = try std.Io.Dir.createFileAbsolute(fs.io, path, .{
        .exclusive = true,
        .read = true,
        .truncate = false,
    });
    file.close(fs.io);
    return .{ .path = path, .fs = fs };
}

pub fn acquireExclusiveLockPath(
    fs: Fs,
    allocator: std.mem.Allocator,
    path_raw: []const u8,
) !LockFile {
    if (std.fs.path.isAbsolute(path_raw)) return acquireAbsoluteExclusiveLock(
        fs,
        allocator,
        path_raw,
    );
    const path = try allocator.dupe(u8, path_raw);
    errdefer allocator.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try ensureDirectoryPathNoSymlinks(fs, parent);
    const existing_stat = fs.directory().statFile(
        fs.io,
        path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing_stat) |stat| {
        if (stat.kind == .sym_link) return error.SymlinkComponent;
    }
    var file = try fs.directory().createFile(fs.io, path, .{
        .exclusive = true,
        .read = true,
        .truncate = false,
    });
    file.close(fs.io);
    return .{ .path = path, .fs = fs };
}

pub fn acquireExclusiveLockPathRetry(
    fs: Fs,
    allocator: std.mem.Allocator,
    path_raw: []const u8,
    timeout_ms: u64,
    retry_interval_ms: u64,
) !LockFile {
    const started_ms = clockMillis(fs, .awake);
    var attempted = false;
    while (!attempted or elapsedMillis(fs, started_ms) < timeout_ms) {
        attempted = true;
        return acquireExclusiveLockPath(fs, allocator, path_raw) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const elapsed_ms = elapsedMillis(fs, started_ms);
                if (elapsed_ms >= timeout_ms) return error.LockBusy;
                const sleep_ms = @min(
                    @min(@max(retry_interval_ms, 1), timeout_ms - elapsed_ms),
                    @as(u64, @intCast(std.math.maxInt(i64))),
                );
                try std.Io.sleep(fs.io, .fromMilliseconds(@intCast(sleep_ms)), .awake);
                continue;
            },
            else => return err,
        };
    }
    return error.LockBusy;
}

pub fn findGitRootAlloc(fs: Fs, allocator: std.mem.Allocator, start: []const u8) ![]u8 {
    var candidate = try std.fs.path.resolve(allocator, &.{start});
    defer allocator.free(candidate);
    var current: []u8 = while (candidate.len != 0) {
        const real = fs.directory().realPathFileAlloc(
            fs.io,
            candidate,
            allocator,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const parent = std.fs.path.dirname(candidate) orelse return err;
                if (std.mem.eql(u8, parent, candidate)) return err;
                const next = try allocator.dupe(u8, parent);
                allocator.free(candidate);
                candidate = next;
                continue;
            },
            else => return err,
        };
        defer allocator.free(real);
        break try allocator.dupe(u8, real);
    } else return error.GitCommandFailed;
    errdefer allocator.free(current);
    while (current.len != 0) {
        const marker = try allocator.print("{s}/.git", .{current});
        defer allocator.free(marker);
        if (fileExists(fs, marker)) return current;

        const parent = std.fs.path.dirname(current) orelse return error.GitCommandFailed;
        if (std.mem.eql(u8, parent, current)) return error.GitCommandFailed;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return error.GitCommandFailed;
}

pub fn ensureLockSidecarGitignored(
    fs: Fs,
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !void {
    const parent = std.fs.path.dirname(store_path) orelse ".";
    const git_root = findGitRootAlloc(fs, allocator, parent) catch |err| switch (err) {
        error.GitCommandFailed => return,
        else => return err,
    };
    defer allocator.free(git_root);

    const public_path = try lockPathAlloc(allocator, store_path);
    defer allocator.free(public_path);
    try ensurePathGitignored(fs, allocator, git_root, public_path);
    const advisory_path = try eventStoreLockPathAlloc(fs, allocator, store_path);
    defer allocator.free(advisory_path);
    try ensurePathGitignored(fs, allocator, git_root, advisory_path);
}

fn ensurePathGitignored(
    fs: Fs,
    allocator: std.mem.Allocator,
    git_root: []const u8,
    path: []const u8,
) !void {
    // Relative locators belong to this directory authority, which need not be
    // the Git root or the process working directory. Bind prospective paths
    // without requiring the lock file to exist yet.
    const absolute_path = if (std.fs.path.isAbsolute(path))
        try std.fs.path.resolve(allocator, &.{path})
    else absolute: {
        const directory_path = try fs.directory().realPathFileAlloc(fs.io, ".", allocator);
        defer allocator.free(directory_path);
        break :absolute try std.fs.path.resolve(allocator, &.{ directory_path, path });
    };
    defer allocator.free(absolute_path);
    const relative_path = try std.fs.path.relative(
        allocator,
        git_root,
        null,
        git_root,
        absolute_path,
    );
    defer allocator.free(relative_path);

    var argv = [_][]const u8{
        "git",
        "-C",
        git_root,
        "check-ignore",
        "-q",
        "--",
        relative_path,
    };
    const result = try std.process.run(allocator, fs.io, .{
        .argv = &argv,
        .stdout_limit = .limited(GitCheckOutputLimit),
        .stderr_limit = .limited(GitCheckOutputLimit),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) return;
    if (result.term == .exited and result.term.exited == 1) return error.LockSidecarNotGitignored;
    return error.GitCommandFailed;
}

test "lock ignore admission covers public and advisory paths" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        fs.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const git_result = try std.process.run(
        std.testing.allocator,
        std.testing.io,
        .{
            .argv = &.{ "git", "init", "--quiet" },
            .cwd = .{ .path = root },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(1024),
        },
    );
    defer std.testing.allocator.free(git_result.stdout);
    defer std.testing.allocator.free(git_result.stderr);
    try std.testing.expect(
        git_result.term == .exited and git_result.term.exited == 0,
    );

    const gitignore = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".gitignore" },
    );
    defer std.testing.allocator.free(gitignore);
    try writeTextAtomic(
        fs,
        std.testing.allocator,
        gitignore,
        "events.jsonl.lock\n",
    );
    const store_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "events.jsonl" },
    );
    defer std.testing.allocator.free(store_path);
    try std.testing.expectError(
        error.LockSidecarNotGitignored,
        ensureLockSidecarGitignored(
            fs,
            std.testing.allocator,
            store_path,
        ),
    );

    try writeTextAtomic(
        fs,
        std.testing.allocator,
        gitignore,
        "events.jsonl.lock\n.durable-store-locks/\n",
    );
    try ensureLockSidecarGitignored(
        fs,
        std.testing.allocator,
        store_path,
    );
}

test "writeTextAtomic creates parent directories and replaces content" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "store.jsonl" });
    defer std.testing.allocator.free(path);

    try writeTextAtomic(fs, std.testing.allocator, path, "{\"ok\":true}\n");
    const first = try tryReadForTest(path);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{\"ok\":true}\n", first);
    try writeTextAtomic(fs, std.testing.allocator, path, "{\"ok\":false}\n");
    const second = try tryReadForTest(path);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("{\"ok\":false}\n", second);
}

test "writeTextCreateNew creates once without overwriting" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "note.md" });
    defer std.testing.allocator.free(path);

    try writeTextCreateNew(fs, std.testing.allocator, path, "first", .{});
    try std.testing.expectError(
        error.PathAlreadyExists,
        writeTextCreateNew(fs, std.testing.allocator, path, "second", .{}),
    );
    const data = try tryReadForTest(path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("first", data);
}

test "writeTextCreateNewAtomic links only complete new files" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "records", "record.json" });
    defer std.testing.allocator.free(path);

    try writeTextCreateNewAtomic(fs, std.testing.allocator, path, "{\"ok\":true}\n", .{});
    try std.testing.expectError(
        error.PathAlreadyExists,
        writeTextCreateNewAtomic(fs, std.testing.allocator, path, "{\"ok\":false}\n", .{}),
    );
    const data = try tryReadForTest(path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("{\"ok\":true}\n", data);
}

test "writeTextCreateNew rejects symlink parent component" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    try tmp.dir.createDir(fs.io, "real", .default_dir);
    try tmp.dir.symLink(fs.io, "real", "link", .{ .is_directory = true });
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "link", "note.md" });
    defer std.testing.allocator.free(path);

    try std.testing.expectError(
        error.SymlinkComponent,
        writeTextCreateNew(fs, std.testing.allocator, path, "payload", .{}),
    );
}

test "readRegularFileNoSymlink rejects symlink and oversized file" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "file.txt" });
    defer std.testing.allocator.free(path);
    const link = try std.fs.path.join(std.testing.allocator, &.{ root, "link.txt" });
    defer std.testing.allocator.free(link);

    try writeTextAtomic(fs, std.testing.allocator, path, "abcd");
    try tmp.dir.symLink(fs.io, "file.txt", "link.txt", .{});
    const data = try readRegularFileNoSymlink(fs, std.testing.allocator, path, 4);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("abcd", data);
    try std.testing.expectError(
        error.FileTooBig,
        readRegularFileNoSymlink(fs, std.testing.allocator, path, 3),
    );
    try std.testing.expectError(
        error.SymlinkComponent,
        readRegularFileNoSymlink(fs, std.testing.allocator, link, 4),
    );
}

test "listSortedRegularFilesNoSymlink sorts and rejects symlink entries" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ root, "notes" });
    defer std.testing.allocator.free(dir_path);
    try ensureDirectoryPathNoSymlinks(fs, dir_path);

    const b = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "b.md" });
    defer std.testing.allocator.free(b);
    const a = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "a.md" });
    defer std.testing.allocator.free(a);
    try writeTextCreateNew(fs, std.testing.allocator, b, "b", .{});
    try writeTextCreateNew(fs, std.testing.allocator, a, "a", .{});

    const names = try listSortedRegularFilesNoSymlink(fs, std.testing.allocator, dir_path, 10, 10);
    defer freeStringList(std.testing.allocator, names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("a.md", names[0]);
    try std.testing.expectEqualStrings("b.md", names[1]);

    var dir = try std.Io.Dir.openDirAbsolute(fs.io, dir_path, .{});
    defer dir.close(fs.io);
    try dir.symLink(fs.io, "a.md", "link.md", .{});
    try std.testing.expectError(
        error.SymlinkComponent,
        listSortedRegularFilesNoSymlink(fs, std.testing.allocator, dir_path, 10, 10),
    );
}

test "appendLineAtomic appends newline-delimited records" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "store.jsonl" });
    defer std.testing.allocator.free(path);

    try appendLineAtomic(fs, std.testing.allocator, path, "{\"n\":1}", 1024);
    try appendLineAtomic(fs, std.testing.allocator, path, "{\"n\":2}", 1024);
    const data = try tryReadForTest(path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("{\"n\":1}\n{\"n\":2}\n", data);
}

test "atomic copy byte budget includes the exact cap" {
    try std.testing.expectEqual(@as(usize, 8), try addCopiedBytesWithinLimit(3, 5, 8));
    try std.testing.expectEqual(@as(usize, 7), try addCopiedBytesWithinLimit(3, 4, 8));
    try std.testing.expectError(error.StreamTooLong, addCopiedBytesWithinLimit(3, 6, 8));
    try std.testing.expectError(
        error.StreamTooLong,
        addCopiedBytesWithinLimit(std.math.maxInt(usize), 1, std.math.maxInt(usize)),
    );
}

test "appendLineAtomic accepts an existing source at the exact cap" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "store.jsonl" });
    defer std.testing.allocator.free(path);

    try writeTextAtomic(fs, std.testing.allocator, path, "12345678");
    try appendLineAtomic(fs, std.testing.allocator, path, "{}", 8);
    const data = try tryReadForTest(path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("12345678\n{}\n", data);
}

test "appendLineStreaming appends without reading capped existing log" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.ndjson" });
    defer std.testing.allocator.free(path);

    const large = try std.testing.allocator.alloc(u8, 2048);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try writeTextAtomic(fs, std.testing.allocator, path, large);
    try std.testing.expectError(
        error.StreamTooLong,
        appendLineAtomic(fs, std.testing.allocator, path, "{\"n\":1}", 1024),
    );
    try appendLineStreaming(fs, std.testing.allocator, path, "{\"n\":1}", .{});

    const data = try tryReadForTest(path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(usize, 2048 + "\n{\"n\":1}\n".len), data.len);
    try std.testing.expectEqualStrings("\n{\"n\":1}\n", data[2048..]);
}

test "EventStore advisory paths use a disjoint reserved namespace" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const first = try std.fs.path.join(std.testing.allocator, &.{ root, "events" });
    defer std.testing.allocator.free(first);
    const formerly_colliding = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "events.event-store" },
    );
    defer std.testing.allocator.free(formerly_colliding);
    const first_advisory = try eventStoreLockPathAlloc(fs, std.testing.allocator, first);
    defer std.testing.allocator.free(first_advisory);
    const second_public = try lockPathAlloc(std.testing.allocator, formerly_colliding);
    defer std.testing.allocator.free(second_public);
    try std.testing.expect(!std.mem.eql(
        u8,
        first_advisory,
        second_public,
    ));

    const reserved_resource = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, event_store_lock_dir_name, "resource" },
    );
    defer std.testing.allocator.free(reserved_resource);
    try std.testing.expectError(
        error.ReservedStorePath,
        lockPathAlloc(std.testing.allocator, reserved_resource),
    );
    try std.testing.expectError(
        error.ReservedStorePath,
        eventStoreLockPathAlloc(fs, std.testing.allocator, reserved_resource),
    );
    const reserved_case_alias = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".DURABLE-STORE-LOCKS", "resource" },
    );
    defer std.testing.allocator.free(reserved_case_alias);
    try std.testing.expectError(
        error.ReservedStorePath,
        lockPathAlloc(std.testing.allocator, reserved_case_alias),
    );
    try std.testing.expectError(
        error.ReservedStorePath,
        eventStoreLockPathAlloc(fs, std.testing.allocator, reserved_case_alias),
    );
}

test "EventStore advisory paths preserve existing filesystem case identity" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const canonical_path = try std.fs.path.join(std.testing.allocator, &.{ root, "Events.jsonl" });
    defer std.testing.allocator.free(canonical_path);
    const case_alias = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(case_alias);
    try writeTextAtomic(fs, std.testing.allocator, canonical_path, "{\"sequence\":1}\n");

    const canonical_stat = try tmp.dir.statFile(fs.io, "Events.jsonl", .{});
    const alias_stat = (try targetNameStat(fs, tmp.dir, "events.jsonl")) orelse return;
    try std.testing.expectEqual(canonical_stat.inode, alias_stat.inode);
    try std.testing.expectEqual(@as(std.Io.File.NLink, 1), canonical_stat.nlink);

    const canonical_advisory = try eventStoreLockPathAlloc(
        fs,
        std.testing.allocator,
        canonical_path,
    );
    defer std.testing.allocator.free(canonical_advisory);
    const alias_advisory = try eventStoreLockPathAlloc(fs, std.testing.allocator, case_alias);
    defer std.testing.allocator.free(alias_advisory);
    try std.testing.expectEqualStrings(canonical_advisory, alias_advisory);
}

test "CAS read custody excludes writers across a canonical path pair" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const binding_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".ledger", ".bindings", "slot.jsonl" },
    );
    defer std.testing.allocator.free(binding_path);
    const slot_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".ledger", "example", "events.jsonl" },
    );
    defer std.testing.allocator.free(slot_path);
    try ensureParentPath(fs, binding_path);
    try ensureParentPath(fs, slot_path);

    var binding_writer = try acquireCasAdvisoryLock(fs, std.testing.allocator, binding_path);
    binding_writer.close(fs.io);
    var slot_writer = try acquireCasAdvisoryLock(fs, std.testing.allocator, slot_path);
    slot_writer.close(fs.io);

    var read_custody = try acquireCasReadLockPair(
        fs,
        std.testing.allocator,
        slot_path,
        binding_path,
    );
    defer read_custody.deinit();
    try std.testing.expectError(
        error.LockBusy,
        acquireCasAdvisoryLock(fs, std.testing.allocator, binding_path),
    );
    try std.testing.expectError(
        error.LockBusy,
        acquireCasAdvisoryLock(fs, std.testing.allocator, slot_path),
    );
}

test "CAS read custody holds the existing member of a partial advisory pair" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const binding_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".ledger", ".bindings", "slot.jsonl" },
    );
    defer std.testing.allocator.free(binding_path);
    const slot_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".ledger", "example", "events.jsonl" },
    );
    defer std.testing.allocator.free(slot_path);
    try ensureParentPath(fs, binding_path);
    try ensureParentPath(fs, slot_path);
    var binding_writer = try acquireCasAdvisoryLock(fs, std.testing.allocator, binding_path);
    binding_writer.close(fs.io);

    var read_custody = try acquireCasReadLockPair(
        fs,
        std.testing.allocator,
        slot_path,
        binding_path,
    );
    defer read_custody.deinit();
    try std.testing.expectEqual(@as(u2, 1), read_custody.count);
    try std.testing.expectError(
        error.LockBusy,
        acquireCasAdvisoryLock(fs, std.testing.allocator, binding_path),
    );
}

test "EventStore case probes distinguish folding from case-variant hardlinks" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(fs.io, "Events", .{ .exclusive = true });
    file.close(fs.io);
    const folding = try targetNameStat(fs, tmp.dir, "events") != null;
    const destination = if (folding) "other-link" else "events";
    try tmp.dir.hardLink("Events", tmp.dir, destination, fs.io, .{});
    const source_stat = try tmp.dir.statFile(fs.io, "Events", .{});
    try std.testing.expectEqual(@as(std.Io.File.NLink, 2), source_stat.nlink);
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.expectEqual(
        @as(?bool, folding),
        try targetNameCaseSensitivity(fs, std.testing.allocator, root, "Events"),
    );
    try std.testing.expectEqual(
        @as(?bool, folding),
        try entryNameCaseSensitivity(fs, std.testing.allocator, tmp.dir, "Events"),
    );
}

test "EventStore changing case-witness metadata remains inconclusive" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(fs.io, "Events", .{ .exclusive = true });
    file.close(fs.io);
    const original = try tmp.dir.statFile(fs.io, "Events", .{});
    var changed = original;
    changed.ctime.nanoseconds += 1;
    const stats: TargetNameStats = .{ .original = original, .alias = changed };
    try std.testing.expectEqual(
        @as(?bool, null),
        try classifyTargetNameStats(fs, std.testing.allocator, tmp.dir, "Events", "events", stats),
    );
    try std.testing.expectEqual(
        @as(?bool, null),
        try caseNamesAreOneDirectoryEntry(fs, tmp.dir, "Missing"),
    );
}

test "Linux case probes preserve known-target search access" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    directory_case_cache = .{};
    defer directory_case_cache = .{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(fs.io, "search-only", .default_dir);
    var parent = try tmp.dir.openDir(fs.io, "search-only", .{
        .iterate = true,
    });
    defer parent.close(fs.io);
    var witness = try parent.createFile(fs.io, "Events.jsonl", .{ .exclusive = true });
    witness.close(fs.io);
    const root = try parent.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const expected = (try targetNameCaseSensitivity(
        fs,
        std.testing.allocator,
        root,
        "Events.jsonl",
    )) orelse return error.SkipZigTest;
    const writable = std.Io.File.Permissions.fromMode(0o700);
    const search_only = std.Io.File.Permissions.fromMode(0o300);
    try parent.setPermissions(fs.io, search_only);
    defer parent.setPermissions(fs.io, writable) catch |err| {
        std.debug.panic("restore test directory permissions: {s}", .{
            @errorName(err),
        });
    };
    try std.testing.expectEqual(
        expected,
        try directoryNameIsCaseInsensitive(fs, std.testing.allocator, root, "Events.jsonl"),
    );
}

test "EventStore case probe does not treat directory symlinks as folding" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    if (try directoryNameIsCaseInsensitive(
        fs,
        std.testing.allocator,
        root,
        "Probe",
    )) return;

    try tmp.dir.createDir(fs.io, "Foo", .default_dir);
    try tmp.dir.symLink(fs.io, "Foo", "foo", .{ .is_directory = true });
    const upper_path = try std.fs.path.join(std.testing.allocator, &.{ root, "Foo", "A.jsonl" });
    defer std.testing.allocator.free(upper_path);
    const lower_path = try std.fs.path.join(std.testing.allocator, &.{ root, "Foo", "a.jsonl" });
    defer std.testing.allocator.free(lower_path);
    const upper_advisory = try eventStoreLockPathAlloc(fs, std.testing.allocator, upper_path);
    defer std.testing.allocator.free(upper_advisory);
    const lower_advisory = try eventStoreLockPathAlloc(fs, std.testing.allocator, lower_path);
    defer std.testing.allocator.free(lower_advisory);

    try std.testing.expect(!std.mem.eql(u8, upper_advisory, lower_advisory));
}

test "EventStore case probe excludes child symlink destinations" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    if (try directoryNameIsCaseInsensitive(
        fs,
        std.testing.allocator,
        root,
        "Probe",
    )) return;

    const witness_path = try std.fs.path.join(std.testing.allocator, &.{ root, "Witness" });
    defer std.testing.allocator.free(witness_path);
    try writeTextAtomic(fs, std.testing.allocator, witness_path, "case-sensitive\n");
    try tmp.dir.symLink(fs.io, "Witness", "witness", .{});
    try std.testing.expect(
        !try directoryNameIsCaseInsensitive(fs, std.testing.allocator, root, "Witness"),
    );
}

test "EventStore case probe targets the requested witness" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var name_buffer: [32]u8 = undefined;
    for (0..1025) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "{d}", .{index});
        var file = try tmp.dir.createFile(fs.io, name, .{ .exclusive = true });
        file.close(fs.io);
    }
    try std.testing.expectEqual(
        @as(?bool, null),
        try targetNameCaseSensitivity(fs, std.testing.allocator, root, "Events.jsonl"),
    );
}

test "EventStore inconclusive case cache rechecks the target witness" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    directory_case_cache = .{};
    defer directory_case_cache = .{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    var witness = try tmp.dir.createFile(fs.io, "Events.jsonl", .{ .exclusive = true });
    witness.close(fs.io);
    const refreshed = (try hostObjectIdentity(fs, root)) orelse
        return error.SkipZigTest;
    directory_case_cache.put(refreshed, .scan_inconclusive);
    _ = try directoryNameIsCaseInsensitive(fs, allocator, root, "Events.jsonl");
    try std.testing.expect(directory_case_cache.get(refreshed).? == .direct);
}

test "findGitRootAlloc walks parents without spawning git" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(fs.io, ".git");
    try tmp.dir.createDirPath(fs.io, "a/b/c");

    const nested = try std.fs.path.join(std.testing.allocator, &.{ root, "a", "b", "c" });
    defer std.testing.allocator.free(nested);
    const found = try findGitRootAlloc(fs, std.testing.allocator, nested);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings(root, found);
}

test "findGitRootAlloc starts from the nearest existing ancestor" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(fs.io, ".git");

    const prospective = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "missing", "nested" },
    );
    defer std.testing.allocator.free(prospective);
    const found = try findGitRootAlloc(fs, std.testing.allocator, prospective);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings(root, found);
}

test "acquireLock is exclusive until released" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "store.jsonl" });
    defer std.testing.allocator.free(path);

    var lock = try acquireLock(fs, std.testing.allocator, path);
    try std.testing.expectError(
        error.PathAlreadyExists,
        acquireLock(fs, std.testing.allocator, path),
    );
    lock.release(std.testing.allocator);
    var second = try acquireLock(fs, std.testing.allocator, path);
    second.release(std.testing.allocator);
}

test "acquireAbsoluteExclusiveLock is exclusive until released" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "locks", "store.lock" });
    defer std.testing.allocator.free(path);

    var lock = try acquireAbsoluteExclusiveLock(fs, std.testing.allocator, path);
    try std.testing.expectError(
        error.PathAlreadyExists,
        acquireAbsoluteExclusiveLock(fs, std.testing.allocator, path),
    );
    lock.release(std.testing.allocator);
    var second = try acquireAbsoluteExclusiveLock(fs, std.testing.allocator, path);
    second.release(std.testing.allocator);
}

pub fn tryReadForTest(path: []const u8) ![]u8 {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    return try readFileAlloc(fs, std.testing.allocator, path, 4096);
}

test "injected sync failure uses supplied authority and cleans create-new staging" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var vtable = io.vtable.*;
    vtable.fileSync = struct {
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }
    }.sync;
    const failing = Fs.anchored(.{ .userdata = io.userdata, .vtable = &vtable }, tmp.dir);
    try std.testing.expectError(
        error.InputOutput,
        writeTextCreateNewAtomic(failing, allocator, "admission.json", "{}", .{}),
    );
    var entries = tmp.dir.iterate();
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try entries.next(io));
    try writeTextCreateNewAtomic(Fs.anchored(io, tmp.dir), allocator, "admission.json", "{}", .{});
}

test "relative Git admission resolves from supplied nested directory authority" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const git_result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "init", "--quiet" },
        .cwd = .{ .path = root },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(git_result.stdout);
    defer allocator.free(git_result.stderr);
    try std.testing.expect(git_result.term == .exited and git_result.term.exited == 0);
    try writeTextAtomic(
        Fs.init(io, tmp.dir),
        allocator,
        ".gitignore",
        "/nested/*.lock\n/nested/.durable-store-locks/\n",
    );
    try tmp.dir.createDir(io, "nested", .default_dir);
    var nested = try tmp.dir.openDir(io, "nested", .{});
    defer nested.close(io);
    try ensureLockSidecarGitignored(Fs.anchored(io, nested), allocator, "events.jsonl");
    try std.testing.expectError(
        error.LockSidecarNotGitignored,
        ensureLockSidecarGitignored(Fs.anchored(io, tmp.dir), allocator, "events.jsonl"),
    );
}
