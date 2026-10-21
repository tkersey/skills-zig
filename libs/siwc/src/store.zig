const std = @import("std");
const builtin = @import("builtin");
const core_io = @import("core_io");
const durable_store = @import("durable_store");
const oauth = @import("oauth.zig");

pub const label_bytes_max = 64;
pub const token_bytes_max = 32 * 1024;
pub const record_bytes_max = 128 * 1024;
pub const accounts_max = 128;
pub const account_locks_max = accounts_max;
pub const directory_entries_max = 1024;
pub const identity_bytes_max = 1024;
pub const scope_bytes_max = 4096;
const host_id_bytes = 45;
const owner_lookup_attempts_max = 4;
const root_path_bytes_max = 4096;

pub const TokenSet = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    id_token: []const u8,
    scope: []const u8,
    expires_at: i64,
    earliest_refresh_at: ?i64 = null,

    pub fn validate(self: TokenSet) !void {
        try validateText(self.access_token, token_bytes_max, false);
        try validateText(self.scope, scope_bytes_max, true);
        if (self.refresh_token) |token| {
            try validateText(token, token_bytes_max, false);
        } else if (oauth.hasPlanScope(self.scope)) return error.RefreshTokenMissing;
        try validateText(self.id_token, token_bytes_max, false);
        if (self.expires_at <= 0) return error.InvalidExpiry;
        if (self.earliest_refresh_at) |earliest| {
            if (earliest < 0) return error.InvalidExpiry;
        }
    }
};

pub const Record = struct {
    version: u32 = 1,
    app: []const u8,
    label: []const u8,
    client_id: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    email: ?[]const u8 = null,
    tokens: ?TokenSet = null,
    refresh_pending: bool = false,

    pub fn validate(self: Record) !void {
        if (self.version != 1) return error.UnsupportedStoreVersion;
        try validateLabel(self.app);
        try validateLabel(self.label);
        if (self.client_id) |id| {
            try validateText(id, identity_bytes_max, false);
            if (std.mem.eql(u8, id, "dynamic_agent_client")) return error.InvalidClientId;
        }
        if (self.subject) |subject| try validateText(subject, identity_bytes_max, false);
        if (self.email) |email| try validateText(email, identity_bytes_max, true);
        if (self.subject != null and self.client_id == null) return error.InvalidRegistration;
        if (self.email != null and self.subject == null) return error.InvalidRegistration;
        if (self.tokens) |tokens| {
            if (self.client_id == null or self.subject == null) return error.InvalidRegistration;
            try tokens.validate();
            if (self.refresh_pending and tokens.refresh_token == null)
                return error.InvalidRefreshState;
        } else if (self.refresh_pending) return error.InvalidRefreshState;
    }
};

pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    app: []u8,
    directory: durable_store.PrivateDirectory,
    mode: Mode,

    pub const Mode = enum { create, read_only };

    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        root_path: []const u8,
        app: []const u8,
        mode: Mode,
    ) !Store {
        try validateRootPath(root_path);
        try validateLabel(app);
        var root = try openRoot(io, root_path, mode);
        defer root.deinit();
        try validateNativeOwner(root.directory.handle);
        var directory = try openChild(&root, app, mode);
        errdefer directory.deinit();
        const iterable = try directory.directory.openDir(io, ".", .{
            .iterate = true,
            .follow_symlinks = false,
        });
        directory.deinit();
        directory = .{ .io = io, .directory = iterable };
        try validateNativeOwner(directory.directory.handle);
        return .{
            .io = io,
            .allocator = allocator,
            .app = try allocator.dupe(u8, app),
            .directory = directory,
            .mode = mode,
        };
    }

    pub fn deinit(self: *Store) void {
        self.directory.deinit();
        self.allocator.free(self.app);
        self.* = undefined;
    }

    pub fn load(self: *const Store, label: []const u8) !std.json.Parsed(Record) {
        try validateLabel(label);
        var leaf_buffer: [label_bytes_max + 16]u8 = undefined;
        const leaf = try accountLeaf(&leaf_buffer, label);
        const raw = try self.readPrivate(leaf, record_bytes_max);
        defer self.allocator.free(raw);
        var parsed = try std.json.parseFromSlice(Record, self.allocator, raw, .{
            .allocate = .alloc_always,
        });
        errdefer parsed.deinit();
        try parsed.value.validate();
        if (!std.mem.eql(u8, parsed.value.app, self.app) or
            !std.mem.eql(u8, parsed.value.label, label)) return error.RegistrationMismatch;
        return parsed;
    }

    pub fn lock(self: *Store, label: []const u8) !Account {
        if (self.mode != .create) return error.ReadOnlyStore;
        try validateLabel(label);
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        var leaf_buffer: [label_bytes_max + 16]u8 = undefined;
        const leaf = try std.fmt.bufPrint(&leaf_buffer, ".account-{s}.lock", .{label});
        return .{
            .store = self,
            .label = owned_label,
            .file = try self.openAccountLock(leaf),
        };
    }

    pub fn list(self: *const Store) ![][]u8 {
        try self.admitDirectory();
        var labels: std.ArrayList([]u8) = .empty;
        errdefer {
            for (labels.items) |label| self.allocator.free(label);
            labels.deinit(self.allocator);
        }
        var iterator = self.directory.directory.iterate();
        for (0..directory_entries_max + 1) |index| {
            const entry = try iterator.next(self.io) orelse {
                std.mem.sort([]u8, labels.items, {}, labelLessThan);
                return labels.toOwnedSlice(self.allocator);
            };
            if (index == directory_entries_max) return error.TooManyDirectoryEntries;
            if (!std.mem.startsWith(u8, entry.name, "account-") or
                !std.mem.endsWith(u8, entry.name, ".json")) continue;
            if (entry.kind != .file) return error.NotFile;
            const label = entry.name[8 .. entry.name.len - 5];
            try validateLabel(label);
            if (labels.items.len == accounts_max) return error.TooManyAccounts;
            const owned_label = try self.allocator.dupe(u8, label);
            errdefer self.allocator.free(owned_label);
            try labels.append(self.allocator, owned_label);
        }
        return error.TooManyDirectoryEntries;
    }

    pub fn freeList(self: *const Store, labels: [][]u8) void {
        for (labels) |label| self.allocator.free(label);
        self.allocator.free(labels);
    }

    pub fn getOrCreateHostId(self: *Store) ![]u8 {
        if (self.mode != .create) return error.ReadOnlyStore;
        const file = try self.openLock(".host.lock");
        defer file.close(self.io);
        if (try self.readHostId()) |host_id| {
            errdefer self.allocator.free(host_id);
            try syncDirectory(self.io, self.directory.directory);
            return host_id;
        }
        var bytes: [16]u8 = undefined;
        try self.io.randomSecure(&bytes);
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        const hex = std.fmt.bytesToHex(bytes, .lower);
        const host_id = try std.fmt.allocPrint(self.allocator, "urn:uuid:{s}-{s}-{s}-{s}-{s}", .{
            hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32],
        });
        errdefer self.allocator.free(host_id);
        try self.publish("host-id", host_id, true);
        return host_id;
    }

    fn readHostId(self: *const Store) !?[]u8 {
        const raw = self.readPrivate("host-id", host_id_bytes) catch |err|
            switch (err) {
                error.FileNotFound => return null,
                else => return err,
            };
        errdefer self.allocator.free(raw);
        try validateHostId(raw);
        return raw;
    }

    fn readPrivate(self: *const Store, leaf: []const u8, limit: usize) ![]u8 {
        try self.admitDirectory();
        const stat = try self.directory.directory.statFile(self.io, leaf, .{
            .follow_symlinks = false,
        });
        try validatePrivateFile(stat);
        const file = try self.directory.directory.openFile(self.io, leaf, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
        defer file.close(self.io);
        try validateNativeOwner(file.handle);
        const opened_stat = try file.stat(self.io);
        try validatePrivateFile(opened_stat);
        if (opened_stat.size > limit) return error.FileTooBig;
        return self.readBounded(file, limit);
    }

    fn readBounded(self: *const Store, file: std.Io.File, limit: usize) ![]u8 {
        var reader = file.reader(self.io, &.{});
        return reader.interface.allocRemaining(self.allocator, .limited(limit)) catch |err|
            switch (err) {
                error.StreamTooLong => error.FileTooBig,
                error.ReadFailed => reader.err orelse err,
                else => err,
            };
    }

    fn openLock(self: *const Store, leaf: []const u8) !std.Io.File {
        try self.admitDirectory();
        const file = self.directory.directory.createFile(self.io, leaf, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = .fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => try self.openExistingLock(leaf),
            error.WouldBlock => return error.AccountBusy,
            else => return err,
        };
        errdefer file.close(self.io);
        try validateNativeOwner(file.handle);
        const stat = try file.stat(self.io);
        try validatePrivateFile(stat);
        if (stat.size != 0) return error.InvalidLock;
        return file;
    }

    fn openAccountLock(self: *const Store, leaf: []const u8) !std.Io.File {
        const inventory = try self.openLock(".inventory.lock");
        defer inventory.close(self.io);
        const stat = self.directory.directory.statFile(self.io, leaf, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                try self.admitAccountLockSlot();
                return self.openLock(leaf);
            },
            else => return err,
        };
        try validatePrivateFile(stat);
        return self.openLock(leaf);
    }

    fn admitAccountLockSlot(self: *const Store) !void {
        var iterator = self.directory.directory.iterate();
        var locks: usize = 0;
        for (0..directory_entries_max + 1) |index| {
            const entry = try iterator.next(self.io) orelse return;
            if (index == directory_entries_max) return error.TooManyDirectoryEntries;
            if (!std.mem.startsWith(u8, entry.name, ".account-") or
                !std.mem.endsWith(u8, entry.name, ".lock")) continue;
            if (entry.kind != .file) return error.NotFile;
            try validateLabel(entry.name[9 .. entry.name.len - 5]);
            locks += 1;
            if (locks >= account_locks_max) return error.TooManyAccountLocks;
        }
        return error.TooManyDirectoryEntries;
    }

    fn openExistingLock(self: *const Store, leaf: []const u8) !std.Io.File {
        const stat = try self.directory.directory.statFile(self.io, leaf, .{
            .follow_symlinks = false,
        });
        try validatePrivateFile(stat);
        return self.directory.directory.openFile(self.io, leaf, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => error.AccountBusy,
            else => err,
        };
    }

    fn publish(self: *const Store, leaf: []const u8, raw: []const u8, new: bool) !void {
        try self.admitDirectory();
        const directory = self.directory.directory;
        const options: durable_store.PublicationOptions = .{
            .permissions = .fromMode(0o600),
            .durability = .file_and_directories_synced,
        };
        const outcome = if (new)
            durable_store.publishCreateNew(self.io, directory, directory, leaf, &.{raw}, options)
        else
            durable_store.publishReplacement(self.io, directory, directory, leaf, &.{raw}, options);
        switch (outcome) {
            .complete => {},
            .not_published, .publication_unknown => |failure| return failure.cause,
            .published_unsynced => return error.DurabilityUnconfirmed,
        }
    }

    fn admitDirectory(self: *const Store) !void {
        try validateNativeOwner(self.directory.directory.handle);
        const stat = try self.directory.directory.stat(self.io);
        if (stat.kind != .directory) return error.NotDir;
        if (stat.permissions.toMode() & 0o077 != 0) return error.InsecurePrivateDirectory;
    }
};

pub const Account = struct {
    store: *Store,
    label: []u8,
    file: std.Io.File,

    pub fn deinit(self: *Account) void {
        self.file.close(self.store.io);
        self.store.allocator.free(self.label);
        self.* = undefined;
    }

    pub fn load(self: *const Account) !std.json.Parsed(Record) {
        return self.store.load(self.label);
    }

    pub fn reserveNew(self: *const Account) !void {
        const inventory = try self.store.openLock(".inventory.lock");
        defer inventory.close(self.store.io);
        const labels = try self.store.list();
        defer self.store.freeList(labels);
        if (labels.len >= accounts_max) return error.TooManyAccounts;
        const record: Record = .{ .app = self.store.app, .label = self.label };
        self.write(record, true) catch |err| switch (err) {
            error.PathAlreadyExists => return error.AccountAlreadyExists,
            else => return err,
        };
    }

    pub fn save(self: *const Account, record: Record) !void {
        try record.validate();
        var previous = try self.load();
        defer previous.deinit();
        try preserveIdentity(previous.value.client_id, record.client_id);
        try preserveIdentity(previous.value.subject, record.subject);
        try self.write(record, false);
    }

    fn write(self: *const Account, record: Record, new: bool) !void {
        try record.validate();
        if (!std.mem.eql(u8, record.app, self.store.app) or
            !std.mem.eql(u8, record.label, self.label)) return error.RegistrationMismatch;
        const raw = try std.json.Stringify.valueAlloc(self.store.allocator, record, .{});
        defer self.store.allocator.free(raw);
        if (raw.len > record_bytes_max) return error.RecordTooLarge;
        var leaf_buffer: [label_bytes_max + 16]u8 = undefined;
        const leaf = try accountLeaf(&leaf_buffer, self.label);
        try self.store.publish(leaf, raw, new);
    }
};

pub fn validateLabel(value: []const u8) !void {
    if (value.len == 0 or value.len > label_bytes_max) return error.InvalidLabel;
    if (!isLowerAlphanumeric(value[0])) return error.InvalidLabel;
    for (value) |byte| {
        if (!isLowerAlphanumeric(byte) and byte != '-' and byte != '_')
            return error.InvalidLabel;
    }
}

fn isLowerAlphanumeric(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9');
}

fn validateText(value: []const u8, limit: usize, spaces: bool) !void {
    if (value.len == 0 or value.len > limit) return error.InvalidRecordField;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidRecordField;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f or (!spaces and byte == ' '))
            return error.InvalidRecordField;
    }
}

fn preserveIdentity(previous: ?[]const u8, next: ?[]const u8) !void {
    if (previous) |expected| {
        const actual = next orelse return error.RegistrationMismatch;
        if (!std.mem.eql(u8, expected, actual)) return error.RegistrationMismatch;
    }
}

fn accountLeaf(buffer: []u8, label: []const u8) ![]u8 {
    return std.fmt.bufPrint(buffer, "account-{s}.json", .{label});
}

fn labelLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn validateRootPath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or path.len <= 1 or path.len > root_path_bytes_max or
        std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var parts = std.mem.tokenizeScalar(u8, path, std.fs.path.sep);
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return error.InvalidPath;
    }
}

fn openRoot(io: std.Io, path: []const u8, mode: Store.Mode) !durable_store.PrivateDirectory {
    if (mode == .read_only)
        return durable_store.PrivateDirectory.open(.init(io, .cwd()), path, .read_only);
    var directory = try core_io.openSearchDirectory(io, .cwd(), "/", .{
        .follow_symlinks = false,
    });
    errdefer directory.close(io);
    var components = std.mem.tokenizeScalar(u8, path, std.fs.path.sep);
    while (components.next()) |component| {
        const child = try openDirectory(io, directory, component, mode);
        errdefer child.close(io);
        if (components.peek() == null) try admitPrivateDirectory(io, child);
        directory.close(io);
        directory = child;
    }
    return .{ .io = io, .directory = directory };
}

fn openChild(
    root: *durable_store.PrivateDirectory,
    app: []const u8,
    mode: Store.Mode,
) !durable_store.PrivateDirectory {
    try admitPrivateDirectory(root.io, root.directory);
    const child = try openDirectory(root.io, root.directory, app, mode);
    errdefer child.close(root.io);
    try admitPrivateDirectory(root.io, child);
    return .{ .io = root.io, .directory = child };
}

fn openDirectory(
    io: std.Io,
    parent: std.Io.Dir,
    leaf: []const u8,
    mode: Store.Mode,
) !std.Io.Dir {
    const child = core_io.openSearchDirectory(io, parent, leaf, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            if (mode == .read_only) return err;
            return createDirectory(io, parent, leaf);
        },
        else => return err,
    };
    errdefer child.close(io);
    if (mode == .create) {
        if (try DirectoryPublication.openExisting(io, parent)) |publication| {
            defer publication.file.close(io);
            try publication.recover(io, parent);
        }
        try syncExistingDirectory(io, child);
        try syncExistingDirectory(io, parent);
    }
    return child;
}

fn createDirectory(io: std.Io, parent: std.Io.Dir, leaf: []const u8) !std.Io.Dir {
    const parent_sync = try openDirectorySync(io, parent);
    defer parent_sync.close(io);
    const publication = try DirectoryPublication.create(io, parent);
    defer publication.file.close(io);
    try publication.recover(io, parent);
    const existing = core_io.openSearchDirectory(io, parent, leaf, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |child| {
        errdefer child.close(io);
        try syncDirectory(io, child);
        try parent_sync.sync(io);
        return child;
    }
    try publication.begin(io, leaf);
    try parent_sync.sync(io);
    parent.createDir(io, leaf, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const child = try core_io.openSearchDirectory(io, parent, leaf, .{
        .follow_symlinks = false,
    });
    errdefer child.close(io);
    try syncDirectory(io, child);
    try parent_sync.sync(io);
    try publication.setState(io, .idle);
    return child;
}

const DirectoryPublication = struct {
    file: std.Io.File,

    const magic = "SIWC-DIRECTORY-1\n";
    const State = enum(u8) { idle, pending };
    const payload_offset = magic.len + 1 + 2;
    const bytes_max = payload_offset + root_path_bytes_max;

    fn name(buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, ".siwc-directory-{d}.lock", .{std.c.geteuid()});
    }

    fn openExisting(io: std.Io, parent: std.Io.Dir) !?DirectoryPublication {
        var buffer: [64]u8 = undefined;
        const leaf = try name(&buffer);
        const stat = parent.statFile(io, leaf, .{ .follow_symlinks = false }) catch |err|
            switch (err) {
                error.FileNotFound => return null,
                else => return err,
            };
        try validatePrivateFile(stat);
        const file = parent.openFile(io, leaf, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.DirectoryBusy,
            else => return err,
        };
        errdefer file.close(io);
        try validateNativeOwner(file.handle);
        try validatePrivateFile(try file.stat(io));
        return .{ .file = file };
    }

    fn create(io: std.Io, parent: std.Io.Dir) !DirectoryPublication {
        var buffer: [64]u8 = undefined;
        const leaf = try name(&buffer);
        const outcome = durable_store.publishCreateNew(io, parent, parent, leaf, &.{
            magic ++ "\x00",
        }, .{
            .permissions = .fromMode(0o600),
            .durability = .file_and_directories_synced,
        });
        switch (outcome) {
            .complete => {},
            .not_published, .publication_unknown => |failure| {
                if (failure.cause != error.PathAlreadyExists) return failure.cause;
            },
            .published_unsynced => |err| return err,
        }
        return try openExisting(io, parent) orelse error.DirectoryPublicationMissing;
    }

    fn begin(self: DirectoryPublication, io: std.Io, leaf: []const u8) !void {
        try validateDirectoryLeaf(leaf);
        try self.setState(io, .idle);
        var length: [2]u8 = undefined;
        std.mem.writeInt(u16, &length, @intCast(leaf.len), .little);
        try self.file.setLength(io, payload_offset + leaf.len);
        try self.file.writePositionalAll(io, &length, magic.len + 1);
        try self.file.writePositionalAll(io, leaf, payload_offset);
        try self.file.sync(io);
        try self.setState(io, .pending);
    }

    fn setState(self: DirectoryPublication, io: std.Io, state: State) !void {
        try self.file.writePositionalAll(io, &.{@backingInt(state)}, magic.len);
        try self.file.sync(io);
    }

    fn pending(self: DirectoryPublication, io: std.Io, buffer: []u8) !?[]const u8 {
        const stat = try self.file.stat(io);
        if (stat.size < magic.len + 1 or stat.size > bytes_max)
            return error.InvalidDirectoryPublication;
        var header: [magic.len + 1]u8 = undefined;
        if (try self.file.readPositionalAll(io, &header, 0) != header.len or
            !std.mem.eql(u8, header[0..magic.len], magic))
            return error.InvalidDirectoryPublication;
        if (header[magic.len] == @backingInt(State.idle)) return null;
        if (header[magic.len] != @backingInt(State.pending))
            return error.InvalidDirectoryPublication;
        var length: [2]u8 = undefined;
        if (try self.file.readPositionalAll(io, &length, magic.len + 1) != length.len)
            return error.InvalidDirectoryPublication;
        const size = std.mem.readInt(u16, &length, .little);
        if (size > buffer.len or stat.size != payload_offset + size)
            return error.InvalidDirectoryPublication;
        const leaf = buffer[0..size];
        if (try self.file.readPositionalAll(io, leaf, payload_offset) != size)
            return error.InvalidDirectoryPublication;
        try validateDirectoryLeaf(leaf);
        return leaf;
    }

    fn recover(self: DirectoryPublication, io: std.Io, parent: std.Io.Dir) !void {
        var buffer: [root_path_bytes_max]u8 = undefined;
        const leaf = try self.pending(io, &buffer) orelse return;
        const parent_sync = try openDirectorySync(io, parent);
        defer parent_sync.close(io);
        const child = core_io.openSearchDirectory(io, parent, leaf, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (child) |directory| {
            defer directory.close(io);
            try syncDirectory(io, directory);
        }
        try parent_sync.sync(io);
        try self.setState(io, .idle);
    }
};

fn validateDirectoryLeaf(leaf: []const u8) !void {
    if (leaf.len == 0 or leaf.len > root_path_bytes_max or
        std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..") or
        std.mem.indexOfAny(u8, leaf, "/\x00") != null)
        return error.InvalidDirectoryPublication;
}

fn syncExistingDirectory(io: std.Io, directory: std.Io.Dir) !void {
    const file = openDirectorySync(io, directory) catch |err| {
        const native_opener = comptime std.Io.Threaded.io(undefined).vtable.dirOpenFile;
        if (err == error.AccessDenied and io.vtable.dirOpenFile == native_opener) return;
        return err;
    };
    defer file.close(io);
    try file.sync(io);
}

fn admitPrivateDirectory(io: std.Io, directory: std.Io.Dir) !void {
    try validateNativeOwner(directory.handle);
    const stat = try directory.stat(io);
    if (stat.kind != .directory) return error.NotDir;
    if (stat.permissions.toMode() & 0o077 != 0) return error.InsecurePrivateDirectory;
}

fn syncDirectory(io: std.Io, directory: std.Io.Dir) !void {
    const file = try openDirectorySync(io, directory);
    defer file.close(io);
    try file.sync(io);
}

fn openDirectorySync(io: std.Io, directory: std.Io.Dir) !std.Io.File {
    return directory.openFile(io, ".", .{
        .allow_directory = true,
        .follow_symlinks = false,
        .path_only = false,
    });
}

fn validatePrivateFile(stat: std.Io.File.Stat) !void {
    if (stat.kind == .sym_link) return error.SymLinkLoop;
    if (stat.kind != .file) return error.NotFile;
    if (stat.nlink != 1) return error.HardlinkTarget;
    if (stat.permissions.toMode() & 0o077 != 0) return error.InsecurePrivateFile;
}

fn validateNativeOwner(handle: std.posix.fd_t) !void {
    const owner = switch (builtin.os.tag) {
        .linux => try linuxOwner(handle),
        .macos => try macosOwner(handle),
        else => return error.UnsupportedPlatform,
    };
    try validateOwner(owner, std.c.geteuid());
}

fn validateOwner(owner: std.c.uid_t, expected: std.c.uid_t) !void {
    if (owner != expected) return error.PrivateOwnerMismatch;
}

fn linuxOwner(handle: std.posix.fd_t) !std.c.uid_t {
    const linux = std.os.linux;
    for (0..owner_lookup_attempts_max) |_| {
        var stat = std.mem.zeroes(linux.Statx);
        const result = linux.statx(handle, "", linux.AT.EMPTY_PATH, .{ .UID = true }, &stat);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (!stat.mask.UID) return error.OwnerLookupFailed;
                return stat.uid;
            },
            .INTR => continue,
            else => return error.OwnerLookupFailed,
        }
    }
    return error.OwnerLookupFailed;
}

fn macosOwner(handle: std.posix.fd_t) !std.c.uid_t {
    for (0..owner_lookup_attempts_max) |_| {
        var stat: std.c.Stat = undefined;
        switch (std.c.errno(std.c.fstat(handle, &stat))) {
            .SUCCESS => return stat.uid,
            .INTR => continue,
            else => return error.OwnerLookupFailed,
        }
    }
    return error.OwnerLookupFailed;
}

fn validateHostId(value: []const u8) !void {
    if (value.len != host_id_bytes or !std.mem.startsWith(u8, value, "urn:uuid:"))
        return error.InvalidHostId;
    for (value[9..], 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return error.InvalidHostId;
        } else if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
            return error.InvalidHostId;
        }
    }
    if (value[23] != '4' or std.mem.indexOfScalar(u8, "89ab", value[28]) == null)
        return error.InvalidHostId;
}

const TestStore = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    store: Store,

    fn init(app: []const u8) !TestStore {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const parent = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(parent);
        const path = try std.fs.path.join(allocator, &.{ parent, "auth" });
        errdefer allocator.free(path);
        return .{
            .tmp = tmp,
            .path = path,
            .store = try Store.open(std.testing.io, allocator, path, app, .create),
        };
    }

    fn deinit(self: *TestStore) void {
        self.store.deinit();
        self.tmp.cleanup();
        std.testing.allocator.free(self.path);
    }
};

fn connectedRecord(app: []const u8, label: []const u8) Record {
    return .{
        .app = app,
        .label = label,
        .client_id = "oaiapp_test",
        .subject = "subject-test",
        .email = "test@example.invalid",
        .tokens = .{
            .access_token = "test-access",
            .refresh_token = "test-refresh",
            .id_token = "test-id",
            .scope = "openid offline_access chatgpt.tokens.use.direct",
            .expires_at = 3600,
        },
    };
}

test "mutable store admission syncs the app parent and retries existing entries after failure" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "auth", .fromMode(0o700));
    var root = try tmp.dir.openDir(io, "auth", .{ .follow_symlinks = false });
    defer root.close(io);
    const path = try root.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const Hooks = struct {
        var root_directory: std.Io.Dir = undefined;
        var root_inode: std.Io.File.INode = undefined;
        var app: []const u8 = undefined;
        var root_syncs: usize = 0;
        var other_syncs: usize = 0;
        var fail_root: bool = false;

        fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            const stat = file.stat(std.testing.io) catch return error.InputOutput;
            if (stat.kind == .directory and stat.inode == root_inode) {
                const child = root_directory.statFile(std.testing.io, app, .{
                    .follow_symlinks = false,
                }) catch |err| switch (err) {
                    error.FileNotFound => {
                        other_syncs += 1;
                        return std.testing.io.vtable.fileSync(userdata, file);
                    },
                    else => return error.InputOutput,
                };
                if (child.kind != .directory) return error.InputOutput;
                root_syncs += 1;
                if (fail_root) return error.InputOutput;
            } else {
                other_syncs += 1;
            }
            return std.testing.io.vtable.fileSync(userdata, file);
        }
    };
    Hooks.root_directory = root;
    Hooks.root_inode = (try root.stat(io)).inode;
    Hooks.app = "created";
    Hooks.root_syncs = 0;
    Hooks.other_syncs = 0;
    Hooks.fail_root = false;
    var vtable = io.vtable.*;
    vtable.fileSync = Hooks.sync;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };

    var created = try Store.open(injected, allocator, path, Hooks.app, .create);
    defer created.deinit();
    try std.testing.expectEqual(@as(usize, 1), Hooks.root_syncs);

    Hooks.app = "retry";
    Hooks.fail_root = true;
    try std.testing.expectError(
        error.InputOutput,
        Store.open(injected, allocator, path, Hooks.app, .create),
    );
    try std.testing.expectEqual(@as(usize, 2), Hooks.root_syncs);
    const failed_child = try root.statFile(io, Hooks.app, .{ .follow_symlinks = false });
    try std.testing.expectEqual(.directory, failed_child.kind);

    Hooks.fail_root = false;
    var retried = try Store.open(injected, allocator, path, Hooks.app, .create);
    defer retried.deinit();
    try std.testing.expectEqual(@as(usize, 5), Hooks.root_syncs);
    try std.testing.expectEqual(
        failed_child.inode,
        (try retried.directory.directory.stat(io)).inode,
    );

    Hooks.fail_root = true;
    const other_syncs = Hooks.other_syncs;
    try std.testing.expect(other_syncs > 0);
    var read_only = try Store.open(injected, allocator, path, Hooks.app, .read_only);
    defer read_only.deinit();
    try std.testing.expectEqual(@as(usize, 5), Hooks.root_syncs);
    try std.testing.expectEqual(other_syncs, Hooks.other_syncs);
}

test "nested private ancestry survives parent sync failures without weakening creation modes" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const Hooks = struct {
        var created: [4]std.Io.File.INode = undefined;
        var created_count: usize = 0;
        var private_from_creation: bool = true;
        var fail_on_creation: usize = 0;
        var failure_parent: std.Io.File.INode = 0;
        var failure_child: std.Io.File.INode = 0;
        var fail: bool = true;
        var syncs: usize = 0;
        var last_sync: std.Io.File.INode = 0;

        fn create(
            userdata: ?*anyopaque,
            parent: std.Io.Dir,
            leaf: []const u8,
            permissions: std.Io.Dir.Permissions,
        ) std.Io.Dir.CreateDirError!void {
            try std.testing.io.vtable.dirCreateDir(userdata, parent, leaf, permissions);
            const stat = parent.statFile(std.testing.io, leaf, .{
                .follow_symlinks = false,
            }) catch return error.Unexpected;
            private_from_creation = private_from_creation and
                permissions.toMode() & 0o777 == 0o700 and
                stat.permissions.toMode() & 0o777 == 0o700;
            if (created_count >= created.len) return error.Unexpected;
            created[created_count] = stat.inode;
            if (created_count == fail_on_creation) {
                failure_child = stat.inode;
                failure_parent = (parent.stat(std.testing.io) catch
                    return error.Unexpected).inode;
            }
            created_count += 1;
        }

        fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            const stat = file.stat(std.testing.io) catch return error.InputOutput;
            const previous = last_sync;
            last_sync = stat.inode;
            syncs += 1;
            if (fail and failure_child != 0 and stat.inode == failure_parent and
                previous == failure_child) return error.InputOutput;
            return std.testing.io.vtable.fileSync(userdata, file);
        }
    };
    var vtable = io.vtable.*;
    vtable.dirCreateDir = Hooks.create;
    vtable.fileSync = Hooks.sync;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    const previous_mask = std.c.umask(0o022);
    defer _ = std.c.umask(previous_mask);
    for ([_]usize{ 0, 2 }) |fail_on_creation| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const parent = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(parent);
        const path = try std.fs.path.join(allocator, &.{ parent, "outer", "inner", "auth" });
        defer allocator.free(path);
        Hooks.created_count = 0;
        Hooks.private_from_creation = true;
        Hooks.fail_on_creation = fail_on_creation;
        Hooks.failure_child = 0;
        Hooks.fail = true;
        Hooks.syncs = 0;
        Hooks.last_sync = 0;
        try std.testing.expectError(
            error.InputOutput,
            Store.open(injected, allocator, path, "example", .create),
        );
        try std.testing.expectEqual(fail_on_creation + 1, Hooks.created_count);
        try std.testing.expect(Hooks.private_from_creation);
        const failed_inode = Hooks.failure_child;
        try std.testing.expectError(
            error.InputOutput,
            Store.open(injected, allocator, path, "example", .create),
        );
        try std.testing.expectEqual(fail_on_creation + 1, Hooks.created_count);
        try std.testing.expectEqual(failed_inode, Hooks.failure_child);
        Hooks.fail = false;
        var store = try Store.open(injected, allocator, path, "example", .create);
        defer store.deinit();
        try std.testing.expectEqual(@as(usize, 4), Hooks.created_count);
        try std.testing.expect(Hooks.private_from_creation);
        Hooks.failure_parent = Hooks.created[1];
        Hooks.failure_child = Hooks.created[2];
        Hooks.fail = true;
        try std.testing.expectError(
            error.InputOutput,
            Store.open(injected, allocator, path, "example", .create),
        );
        const syncs = Hooks.syncs;
        var read_only = try Store.open(injected, allocator, path, "example", .read_only);
        defer read_only.deinit();
        try std.testing.expectEqual(syncs, Hooks.syncs);
        try std.testing.expectEqual(@as(usize, 4), Hooks.created_count);
    }
}

test "mutable stores traverse search-only completed and externally supplied ancestry" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |completed| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(io, "ancestor", .fromMode(0o700));
        const ancestor = try tmp.dir.openDir(io, "ancestor", .{});
        defer ancestor.close(io);
        const parent = try ancestor.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(parent);
        const path = try std.fs.path.join(allocator, &.{ parent, "auth" });
        defer allocator.free(path);
        if (completed) {
            var initial = try Store.open(io, allocator, path, "example", .create);
            initial.deinit();
        } else {
            try ancestor.createDir(io, "auth", .fromMode(0o700));
            const root = try ancestor.openDir(io, "auth", .{});
            defer root.close(io);
            try root.createDir(io, "example", .fromMode(0o700));
        }
        try ancestor.setPermissions(io, .fromMode(0o100));
        defer ancestor.setPermissions(io, .fromMode(0o700)) catch |err| {
            std.debug.panic("restore ancestor permissions: {s}", .{@errorName(err)});
        };
        var store = try Store.open(io, allocator, path, "example", .create);
        defer store.deinit();
        const host = try store.getOrCreateHostId();
        defer allocator.free(host);
        var account = try store.lock("default");
        defer account.deinit();
        try account.reserveNew();
        try account.save(connectedRecord("example", "default"));
        var read_only = try Store.open(io, allocator, path, "example", .read_only);
        defer read_only.deinit();
        var record = try read_only.load("default");
        defer record.deinit();
        try std.testing.expectEqualStrings("subject-test", record.value.subject.?);
    }
}

test "pending directory publication survives closed handles and fences sibling mutation" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try TestStore.init("existing");
    defer fixture.deinit();
    const root = try fixture.tmp.dir.openDir(io, "auth", .{});
    defer root.close(io);
    const Hooks = struct {
        var root_directory: std.Io.Dir = undefined;
        var inode: std.Io.File.INode = 0;

        fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            const stat = file.stat(std.testing.io) catch return error.InputOutput;
            if (stat.kind == .directory and stat.inode == inode) {
                _ = root_directory.statFile(std.testing.io, "created", .{}) catch
                    return std.testing.io.vtable.fileSync(userdata, file);
                return error.InputOutput;
            }
            return std.testing.io.vtable.fileSync(userdata, file);
        }
    };
    Hooks.root_directory = root;
    Hooks.inode = (try root.stat(io)).inode;
    var vtable = io.vtable.*;
    vtable.fileSync = Hooks.sync;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.InputOutput, Store.open(
        injected,
        allocator,
        fixture.path,
        "created",
        .create,
    ));
    const failed_inode = (try root.statFile(io, "created", .{})).inode;
    try root.setPermissions(io, .fromMode(0o100));
    defer root.setPermissions(io, .fromMode(0o700)) catch |err| {
        std.debug.panic("restore root permissions: {s}", .{@errorName(err)});
    };
    try std.testing.expectError(error.AccessDenied, Store.open(
        io,
        allocator,
        fixture.path,
        "created",
        .create,
    ));
    try std.testing.expectError(error.AccessDenied, Store.open(
        io,
        allocator,
        fixture.path,
        "existing",
        .create,
    ));
    if (root.statFile(io, "Created", .{})) |alias| {
        if (alias.inode == failed_inode) try std.testing.expectError(
            error.AccessDenied,
            openDirectory(io, root, "Created", .create),
        );
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);
    var read_only = try Store.open(injected, allocator, fixture.path, "existing", .read_only);
    read_only.deinit();
    try root.setPermissions(io, .fromMode(0o700));
    var recovered = try Store.open(io, allocator, fixture.path, "created", .create);
    defer recovered.deinit();
    try std.testing.expectEqual(failed_inode, (try recovered.directory.directory.stat(io)).inode);
    try root.setPermissions(io, .fromMode(0o100));
    var completed = try Store.open(io, allocator, fixture.path, "existing", .create);
    completed.deinit();
}

test "unreadable parents reject missing children before creating publication state" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o100));
    defer tmp.dir.setPermissions(io, .fromMode(0o700)) catch |err| {
        std.debug.panic("restore temporary permissions: {s}", .{@errorName(err)});
    };
    try std.testing.expectError(error.AccessDenied, openDirectory(io, tmp.dir, "missing", .create));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "missing", .{}));
    var name_buffer: [64]u8 = undefined;
    const name = try DirectoryPublication.name(&name_buffer);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, name, .{}));
}

test "directory publication keeps its locked inode and rejects malformed pending records" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const publication = try DirectoryPublication.create(io, tmp.dir);
    defer publication.file.close(io);
    const inode = (try publication.file.stat(io)).inode;
    try std.testing.expectError(
        error.DirectoryBusy,
        DirectoryPublication.openExisting(io, tmp.dir),
    );
    try std.testing.expectError(error.DirectoryBusy, createDirectory(io, tmp.dir, "blocked"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "blocked", .{}));
    var buffer: [root_path_bytes_max]u8 = undefined;
    try publication.file.writePositionalAll(io, "unfinished", DirectoryPublication.magic.len + 1);
    try std.testing.expectEqual(null, try publication.pending(io, &buffer));
    try publication.begin(io, "child");
    try std.testing.expectEqualStrings("child", (try publication.pending(io, &buffer)).?);
    try publication.recover(io, tmp.dir);
    try std.testing.expectEqual(null, try publication.pending(io, &buffer));
    try std.testing.expectEqual(inode, (try publication.file.stat(io)).inode);
    for ([_][]const u8{ "", ".", "..", "../escape", "bad/leaf", "bad\x00leaf" }) |bad| {
        try std.testing.expectError(error.InvalidDirectoryPublication, publication.begin(io, bad));
    }
    try publication.begin(io, "child");
    try publication.file.writePositionalAll(io, "../xx", DirectoryPublication.payload_offset);
    try std.testing.expectError(
        error.InvalidDirectoryPublication,
        publication.recover(io, tmp.dir),
    );
    try publication.file.writePositionalAll(io, &.{99}, DirectoryPublication.magic.len);
    try std.testing.expectError(
        error.InvalidDirectoryPublication,
        publication.recover(io, tmp.dir),
    );
    try publication.file.writePositionalAll(io, "BROKEN", 0);
    try std.testing.expectError(
        error.InvalidDirectoryPublication,
        publication.recover(io, tmp.dir),
    );
}

test "directory publication state sync failures cannot acknowledge an incomplete edge" {
    const io = std.testing.io;
    const Hooks = struct {
        var marker_inode: std.Io.File.INode = 0;
        var fail_pending: bool = false;
        var saw_pending: bool = false;
        var creates: usize = 0;

        fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            const stat = file.stat(std.testing.io) catch return error.InputOutput;
            if (stat.kind == .file and stat.inode == marker_inode) {
                var state: [1]u8 = undefined;
                const count = file.readPositionalAll(
                    std.testing.io,
                    &state,
                    DirectoryPublication.magic.len,
                ) catch return error.InputOutput;
                if (count != 1) return error.InputOutput;
                if (state[0] == 1) {
                    saw_pending = true;
                    if (fail_pending) return error.InputOutput;
                } else if (saw_pending and !fail_pending) return error.InputOutput;
            }
            return std.testing.io.vtable.fileSync(userdata, file);
        }

        fn create(
            userdata: ?*anyopaque,
            parent: std.Io.Dir,
            leaf: []const u8,
            permissions: std.Io.Dir.Permissions,
        ) std.Io.Dir.CreateDirError!void {
            creates += 1;
            return std.testing.io.vtable.dirCreateDir(userdata, parent, leaf, permissions);
        }
    };
    var vtable = io.vtable.*;
    vtable.fileSync = Hooks.sync;
    vtable.dirCreateDir = Hooks.create;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    for ([_]bool{ true, false }) |fail_pending| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const publication = try DirectoryPublication.create(io, tmp.dir);
        Hooks.marker_inode = (try publication.file.stat(io)).inode;
        publication.file.close(io);
        Hooks.fail_pending = fail_pending;
        Hooks.saw_pending = false;
        Hooks.creates = 0;
        try std.testing.expectError(error.InputOutput, createDirectory(injected, tmp.dir, "child"));
        try std.testing.expect(Hooks.saw_pending);
        if (fail_pending) {
            try std.testing.expectEqual(@as(usize, 0), Hooks.creates);
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "child", .{}));
        } else try std.testing.expectEqual(@as(usize, 1), Hooks.creates);
        const child = try openDirectory(io, tmp.dir, "child", .create);
        child.close(io);
        const reopened = (try DirectoryPublication.openExisting(io, tmp.dir)).?;
        defer reopened.file.close(io);
        try std.testing.expectEqual(Hooks.marker_inode, (try reopened.file.stat(io)).inode);
        var buffer: [root_path_bytes_max]u8 = undefined;
        try std.testing.expectEqual(null, try reopened.pending(io, &buffer));
    }
}

test "directory sync admission propagates substituted permission errors" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var vtable = io.vtable.*;
    vtable.dirOpenFile = struct {
        fn open(
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: std.Io.Dir.OpenFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            return error.AccessDenied;
        }
    }.open;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.AccessDenied, syncExistingDirectory(injected, tmp.dir));
}

test "directory publication rejects reserved name collisions without replacing them" {
    const io = std.testing.io;
    var buffer: [64]u8 = undefined;
    const name = try DirectoryPublication.name(&buffer);
    const Kind = enum { malformed, shared, symlink, hardlink };
    for ([_]Kind{ .malformed, .shared, .symlink, .hardlink }) |kind| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try tmp.dir.createFile(io, "original", .{
            .read = true,
            .permissions = .fromMode(0o600),
        });
        defer file.close(io);
        try file.writePositionalAll(io, "reserved user content", 0);
        switch (kind) {
            .malformed, .shared => try tmp.dir.rename("original", tmp.dir, name, io),
            .symlink => try tmp.dir.symLink(io, "original", name, .{}),
            .hardlink => try tmp.dir.hardLink("original", tmp.dir, name, io, .{}),
        }
        if (kind == .shared) try file.setPermissions(io, .fromMode(0o644));
        const expected = switch (kind) {
            .malformed => error.InvalidDirectoryPublication,
            .shared => error.InsecurePrivateFile,
            .symlink => error.SymLinkLoop,
            .hardlink => error.HardlinkTarget,
        };
        try std.testing.expectError(expected, createDirectory(io, tmp.dir, "child"));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "child", .{}));
        var contents: [64]u8 = undefined;
        const length = try file.readPositionalAll(io, &contents, 0);
        try std.testing.expectEqualStrings("reserved user content", contents[0..length]);
    }
}

test "host publication retries cannot return an identifier before directory durability" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    const Hooks = struct {
        var app_inode: std.Io.File.INode = 0;
        var fail: bool = true;
        var file_syncs: usize = 0;
        var app_syncs: usize = 0;

        fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            const stat = file.stat(std.testing.io) catch return error.InputOutput;
            if (stat.kind == .directory and stat.inode == app_inode) {
                app_syncs += 1;
                if (fail) return error.InputOutput;
            } else if (stat.kind == .file) {
                file_syncs += 1;
            }
            return std.testing.io.vtable.fileSync(userdata, file);
        }
    };
    Hooks.app_inode = (try fixture.store.directory.directory.stat(io)).inode;
    Hooks.fail = true;
    Hooks.file_syncs = 0;
    Hooks.app_syncs = 0;
    var vtable = io.vtable.*;
    vtable.fileSync = Hooks.sync;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    fixture.store.io = injected;
    try std.testing.expectError(error.DurabilityUnconfirmed, fixture.store.getOrCreateHostId());
    try std.testing.expectEqual(@as(usize, 1), Hooks.file_syncs);
    try std.testing.expectEqual(@as(usize, 1), Hooks.app_syncs);
    const published = (try fixture.store.readHostId()).?;
    defer allocator.free(published);
    try std.testing.expectError(error.InputOutput, fixture.store.getOrCreateHostId());
    try std.testing.expectEqual(@as(usize, 2), Hooks.app_syncs);
    try std.testing.expectError(
        error.InputOutput,
        Store.open(injected, allocator, fixture.path, "example", .create),
    );
    Hooks.fail = false;
    const retried = try fixture.store.getOrCreateHostId();
    defer allocator.free(retried);
    try std.testing.expectEqualStrings(published, retried);
    var reopened = try Store.open(injected, allocator, fixture.path, "example", .create);
    defer reopened.deinit();
    Hooks.fail = true;
    try std.testing.expectError(error.InputOutput, reopened.getOrCreateHostId());
    Hooks.fail = false;
    const stable = try reopened.getOrCreateHostId();
    defer allocator.free(stable);
    try std.testing.expectEqualStrings(published, stable);
    try std.testing.expectEqual(@as(usize, 1), Hooks.file_syncs);
}

test "account records preserve pending connected refreshing and signed-out phases" {
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    var account = try fixture.store.lock("personal");
    defer account.deinit();
    try account.reserveNew();
    try std.testing.expectError(error.AccountAlreadyExists, account.reserveNew());
    var pending = try account.load();
    defer pending.deinit();
    try std.testing.expectEqual(@as(?TokenSet, null), pending.value.tokens);
    var registered = pending.value;
    registered.client_id = "oaiapp_test";
    try account.save(registered);
    var connected = connectedRecord("example", "personal");
    try account.save(connected);
    connected.refresh_pending = true;
    try account.save(connected);
    var refreshing = try account.load();
    defer refreshing.deinit();
    try std.testing.expect(refreshing.value.refresh_pending);
    try std.testing.expectEqualStrings("test-refresh", refreshing.value.tokens.?.refresh_token.?);
    var signed_out = connected;
    signed_out.tokens = null;
    signed_out.refresh_pending = false;
    try account.save(signed_out);
    var retained = try account.load();
    defer retained.deinit();
    try std.testing.expectEqualStrings("oaiapp_test", retained.value.client_id.?);
    try std.testing.expectEqualStrings("subject-test", retained.value.subject.?);
    try std.testing.expectEqual(@as(?TokenSet, null), retained.value.tokens);
}

test "record mutation cannot substitute or erase a bound identity" {
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    var account = try fixture.store.lock("personal");
    defer account.deinit();
    try account.reserveNew();
    const connected = connectedRecord("example", "personal");
    try account.save(connected);
    var changed = connected;
    changed.client_id = "oaiapp_other";
    try std.testing.expectError(error.RegistrationMismatch, account.save(changed));
    changed = connected;
    changed.subject = "other-subject";
    try std.testing.expectError(error.RegistrationMismatch, account.save(changed));
    changed = connected;
    changed.label = "other";
    try std.testing.expectError(error.RegistrationMismatch, account.save(changed));
    changed = .{ .app = "example", .label = "personal" };
    try std.testing.expectError(error.RegistrationMismatch, account.save(changed));
    var loaded = try account.load();
    defer loaded.deinit();
    try std.testing.expectEqualStrings("subject-test", loaded.value.subject.?);
    try std.testing.expectEqualStrings("test-access", loaded.value.tokens.?.access_token);
}

test "kernel session lock survives account replacement and releases on close" {
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    var first = try fixture.store.lock("personal");
    try first.reserveNew();
    var other = try Store.open(
        std.testing.io,
        std.testing.allocator,
        fixture.path,
        "example",
        .create,
    );
    defer other.deinit();
    try std.testing.expectError(error.AccountBusy, other.lock("personal"));
    try first.save(connectedRecord("example", "personal"));
    try std.testing.expectError(error.AccountBusy, other.lock("personal"));
    first.deinit();
    var second = try other.lock("personal");
    defer second.deinit();
    var loaded = try second.load();
    defer loaded.deinit();
    try std.testing.expectEqualStrings("subject-test", loaded.value.subject.?);
}

test "account lock namespaces cannot collide with host or inventory locks" {
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    for ([_][]const u8{ "host", "inventory" }) |label| {
        var account = try fixture.store.lock(label);
        defer account.deinit();
        try account.reserveNew();
        const host = try fixture.store.getOrCreateHostId();
        defer std.testing.allocator.free(host);
        try validateHostId(host);
        var record = try account.load();
        defer record.deinit();
        try std.testing.expectEqualStrings(label, record.value.label);
    }
}

test "account lock admission bounds interrupted reservations and preserves existing slots" {
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    for (0..account_locks_max) |index| {
        var buffer: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&buffer, "slot-{d}", .{index});
        var account = try fixture.store.lock(label);
        account.deinit();
    }
    try std.testing.expectError(error.TooManyAccountLocks, fixture.store.lock("overflow"));
    try std.testing.expectError(
        error.FileNotFound,
        fixture.store.directory.directory.statFile(std.testing.io, ".account-overflow.lock", .{}),
    );
    var recovering = try fixture.store.lock("slot-0");
    defer recovering.deinit();
    try recovering.reserveNew();
    var record = try recovering.load();
    defer record.deinit();
    try std.testing.expectEqualStrings("slot-0", record.value.label);
    const labels = try fixture.store.list();
    defer fixture.store.freeList(labels);
    try std.testing.expectEqual(@as(usize, 1), labels.len);
    const host = try fixture.store.getOrCreateHostId();
    defer std.testing.allocator.free(host);
    try validateHostId(host);
}

test "app profiles and host identifiers remain separate and stable" {
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    const first = try fixture.store.getOrCreateHostId();
    defer std.testing.allocator.free(first);
    const repeated = try fixture.store.getOrCreateHostId();
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings(first, repeated);
    try validateHostId(first);
    var other = try Store.open(
        std.testing.io,
        std.testing.allocator,
        fixture.path,
        "second",
        .create,
    );
    defer other.deinit();
    const second = try other.getOrCreateHostId();
    defer std.testing.allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    var account = try fixture.store.lock("personal");
    defer account.deinit();
    try account.reserveNew();
    try std.testing.expectError(error.FileNotFound, other.load("personal"));
}

test "read-only inspection lists accounts and cannot create authentication state" {
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    var second = try fixture.store.lock("zebra");
    defer second.deinit();
    try second.reserveNew();
    var first = try fixture.store.lock("alpha");
    defer first.deinit();
    try first.reserveNew();
    var read_only = try Store.open(
        std.testing.io,
        std.testing.allocator,
        fixture.path,
        "example",
        .read_only,
    );
    defer read_only.deinit();
    const labels = try read_only.list();
    defer read_only.freeList(labels);
    try std.testing.expectEqual(@as(usize, 2), labels.len);
    try std.testing.expectEqualStrings("alpha", labels[0]);
    try std.testing.expectEqualStrings("zebra", labels[1]);
    try std.testing.expectError(error.ReadOnlyStore, read_only.lock("new"));
    try std.testing.expectError(error.ReadOnlyStore, read_only.getOrCreateHostId());
}

test "private records reject shared permissions hardlinks and symlinks" {
    const io = std.testing.io;
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    var account = try fixture.store.lock("personal");
    defer account.deinit();
    try account.reserveNew();
    const directory = fixture.store.directory.directory;
    const leaf = "account-personal.json";
    try directory.setFilePermissions(io, leaf, .fromMode(0o644), .{});
    try std.testing.expectError(error.InsecurePrivateFile, account.load());
    try directory.setFilePermissions(io, leaf, .fromMode(0o600), .{});
    try directory.hardLink(leaf, directory, "alias", io, .{});
    try std.testing.expectError(error.HardlinkTarget, account.load());
    try directory.deleteFile(io, "alias");
    try directory.rename(leaf, directory, "original", io);
    try directory.symLink(io, "original", leaf, .{});
    try std.testing.expectError(error.SymLinkLoop, account.load());
    try std.testing.expectError(
        error.SymLinkLoop,
        account.save(.{ .app = "example", .label = "personal" }),
    );
}

test "credential ownership must match the effective user even with private permission bits" {
    const owner = std.c.geteuid();
    try validateOwner(owner, owner);
    try std.testing.expectError(error.PrivateOwnerMismatch, validateOwner(owner +% 1, owner));
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    try validateNativeOwner(fixture.store.directory.directory.handle);
    var account = try fixture.store.lock("personal");
    defer account.deinit();
    try validateNativeOwner(account.file.handle);
    try account.reserveNew();
    var record = try account.load();
    defer record.deinit();
    try std.testing.expectEqualStrings("personal", record.value.label);
}

test "same-handle reads retain their byte bound when a file grows after admission" {
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    const file = try fixture.store.directory.directory.createFile(std.testing.io, "growing", .{
        .read = true,
        .permissions = .fromMode(0o600),
    });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "1234", 0);
    const admitted = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u64, 4), admitted.size);
    try file.writePositionalAll(std.testing.io, "5678", 4);
    try std.testing.expectError(error.FileTooBig, fixture.store.readBounded(file, 4));
}

test "FIFO preflight refuses credential and host files before blocking open" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    const linux = std.os.linux;
    for ([_][:0]const u8{ "account-personal.json", "host-id" }) |leaf| {
        const result = linux.mknodat(
            fixture.store.directory.directory.handle,
            leaf,
            linux.S.IFIFO | 0o600,
            0,
        );
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
    }
    try std.testing.expectError(error.NotFile, fixture.store.load("personal"));
    try std.testing.expectError(error.NotFile, fixture.store.getOrCreateHostId());
}

test "private directory admission rejects unsafe roots and path aliases" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    try fixture.tmp.dir.setFilePermissions(io, "auth", .fromMode(0o755), .{});
    try std.testing.expectError(
        error.InsecurePrivateDirectory,
        Store.open(io, allocator, fixture.path, "example", .create),
    );
    const permissions = try fixture.tmp.dir.statFile(io, "auth", .{});
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o755),
        permissions.permissions.toMode() & 0o777,
    );
    try fixture.tmp.dir.setFilePermissions(io, "auth", .fromMode(0o700), .{});
    try fixture.tmp.dir.rename("auth", fixture.tmp.dir, "original", io);
    try fixture.tmp.dir.symLink(io, "original", "auth", .{ .is_directory = true });
    try std.testing.expectError(
        error.NotDir,
        Store.open(io, allocator, fixture.path, "x", .create),
    );
    for ([_][]const u8{ "", "/", "relative", "/tmp/../private", "/tmp/./private" }) |path| {
        try std.testing.expectError(
            error.InvalidPath,
            Store.open(io, allocator, path, "x", .create),
        );
    }
}

test "record validation rejects invalid phases fields and byte boundaries" {
    var record = connectedRecord("example", "personal");
    try record.validate();
    record.version = 2;
    try std.testing.expectError(error.UnsupportedStoreVersion, record.validate());
    record = connectedRecord("example", "personal");
    record.client_id = "dynamic_agent_client";
    try std.testing.expectError(error.InvalidClientId, record.validate());
    record = connectedRecord("example", "personal");
    record.subject = null;
    try std.testing.expectError(error.InvalidRegistration, record.validate());
    record = .{ .app = "example", .label = "personal", .refresh_pending = true };
    try std.testing.expectError(error.InvalidRefreshState, record.validate());
    record = connectedRecord("example", "personal");
    record.tokens.?.access_token = "bad\r\nheader";
    try std.testing.expectError(error.InvalidRecordField, record.validate());
    record = connectedRecord("example", "personal");
    record.tokens.?.expires_at = 0;
    try std.testing.expectError(error.InvalidExpiry, record.validate());
    record = connectedRecord("example", "personal");
    record.tokens.?.earliest_refresh_at = -1;
    try std.testing.expectError(error.InvalidExpiry, record.validate());
    var maximum: [label_bytes_max]u8 = undefined;
    @memset(&maximum, 'a');
    try validateLabel(&maximum);
    var oversized: [label_bytes_max + 1]u8 = undefined;
    @memset(&oversized, 'a');
    try std.testing.expectError(error.InvalidLabel, validateLabel(&oversized));
    for ([_][]const u8{ "", ".", "..", "a/b", "Upper", "a b", "-leading" }) |label| {
        try std.testing.expectError(error.InvalidLabel, validateLabel(label));
    }
}

test "untrusted JSON rejects types missing data duplicates and mismatched registration" {
    var fixture = try TestStore.init("example");
    defer fixture.deinit();
    const invalid = [_][]const u8{
        "{}",
        "{\"app\":false,\"label\":\"personal\"}",
        "{\"app\":\"example\",\"label\":null}",
        "{\"app\":\"example\",\"app\":\"other\",\"label\":\"personal\"}",
        "{\"app\":\"other\",\"label\":\"personal\"}",
        "{\"app\":\"example\",\"label\":\"other\"}",
        "{\"app\":\"example\",\"label\":\"personal\",\"refresh_pending\":\"yes\"}",
    };
    for (invalid) |raw| {
        try fixture.store.publish("account-personal.json", raw, false);
        if (fixture.store.load("personal")) |parsed| {
            parsed.deinit();
            return error.InvalidRecordAccepted;
        } else |_| {}
    }
    const oversized = try std.testing.allocator.alloc(u8, record_bytes_max + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try fixture.store.publish("account-personal.json", oversized, false);
    try std.testing.expectError(error.FileTooBig, fixture.store.load("personal"));
}
