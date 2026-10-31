const std = @import("std");
const storage_root = @import("storage_root");
const durable_store = @import("durable_store");
const definition_core = @import("definition_core");
const preparation = @import("preparation.zig");

pub const workspace_path = ".preparation";
pub const record_path = ".preparation/operation.json";
pub const record_max_bytes: usize = 1024 * 1024;
pub const provenance_max_bytes: usize = 64 * 1024;
const record_schema = "ledger-preparation/v1";

pub const Phase = enum { absent, capturing, ready, installed, finalized };

pub const Report = struct {
    phase: Phase = .absent,
    installed: bool = false,
    observed_by: enum { inspection, reconciliation } = .inspection,
    activity: enum { inspection, cleanup } = .inspection,
    complete: bool = false,
    files: usize = 0,
    bytes: usize = 0,
    reclaimed_bytes: usize = 0,
};

const Witness = struct {
    path: []const u8,
    digest: []const u8,
    length: usize,
    inode: std.Io.File.INode,
};

const Record = struct {
    schema: []const u8 = record_schema,
    phase: Phase,
    installed: bool = false,
    files: []const Witness,
    provenance: std.json.Value,
};

pub const Workspace = struct {
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    guard: std.Io.File,
    ready_digest: ?[]u8 = null,
    installed_record: ?[]u8 = null,
    reclaimed_bytes: usize = 0,

    pub fn acquire(scope: *storage_root.Scope, allocator: std.mem.Allocator) !Workspace {
        if (!scope.fs.isPinned()) return error.PreparationRequiresManagedRoot;
        const previous = scope.mutation_state;
        if (previous != true) scope.mutation_state = null;
        var created = false;
        const guard = try durable_store.acquireCasAdvisoryLockObserved(
            scope.fs,
            allocator,
            workspace_path,
            &created,
        );
        scope.mutation_state = if (created) true else previous;
        return .{ .scope = scope, .allocator = allocator, .guard = guard };
    }

    pub fn deinit(self: *Workspace) void {
        if (self.ready_digest) |value| self.allocator.free(value);
        if (self.installed_record) |value| self.allocator.free(value);
        self.guard.close(self.scope.fs.io);
        self.* = undefined;
    }

    pub fn reconcile(self: *Workspace, limits: preparation.Limits, apply: bool) !Report {
        var observation: ?Report = null;
        try self.reconcileObserved(limits, apply, &observation);
        return observation.?;
    }

    pub fn reconcileObserved(
        self: *Workspace,
        limits: preparation.Limits,
        apply: bool,
        observation: *?Report,
    ) !void {
        observation.* = null;
        defer if (observation.*) |*report| {
            report.observed_by = .reconciliation;
            self.reclaimed_bytes += report.reclaimed_bytes;
        };
        try reconcileLocked(self.scope, self.allocator, limits, apply, observation);
    }

    pub fn stage(
        self: *Workspace,
        history: *const preparation.History,
        provenance_json: []const u8,
        limits: preparation.Limits,
    ) !void {
        try limits.validate();
        if (self.ready_digest != null) return error.PreparationAlreadyStaged;
        if (history.files.items.len == 0 or history.files.items.len > limits.max_files) {
            return error.PreparationFileBoundExceeded;
        }
        if (provenance_json.len > provenance_max_bytes) {
            return error.PreparationMetadataBoundExceeded;
        }
        const parsed_provenance = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            provenance_json,
            .{ .duplicate_field_behavior = .@"error" },
        );
        defer parsed_provenance.deinit();
        const witnesses = try prepareWitnesses(self.allocator, history, limits);
        defer self.allocator.free(witnesses);
        const maximum_record = try renderRecord(self.allocator, .{
            .phase = .capturing,
            .files = witnesses,
            .provenance = parsed_provenance.value,
        });
        defer self.allocator.free(maximum_record);
        _ = try self.reconcile(limits, true);
        if (self.scope.mutation_state != true) self.scope.mutation_state = null;
        try durable_store.ensurePrivateDirectoryPathNoSymlinks(self.scope.fs, workspace_path);
        self.scope.mutation_state = true;
        var directory = try self.scope.fs.directory().openDir(self.scope.fs.io, workspace_path, .{
            .follow_symlinks = false,
        });
        defer directory.close(self.scope.fs.io);
        try self.capturePayloads(history, witnesses, parsed_provenance.value, directory, limits);
    }

    fn capturePayloads(
        self: *Workspace,
        history: *const preparation.History,
        witnesses: []Witness,
        provenance: std.json.Value,
        directory: std.Io.Dir,
        limits: preparation.Limits,
    ) !void {
        var record: Record = .{
            .phase = .capturing,
            .files = &.{},
            .provenance = provenance,
        };
        try writeRecord(self.scope, self.allocator, directory, record);
        var created: usize = 0;
        var recorded = false;
        errdefer {
            if (!recorded) {
                record.files = witnesses[0..created];
                writeRecord(self.scope, self.allocator, directory, record) catch |err| {
                    reportCleanupFailure(self.scope.fs.io, "record ownership", err);
                };
            }
            _ = self.reconcile(limits, true) catch |err| {
                reportCleanupFailure(self.scope.fs.io, "release capture", err);
            };
        }
        try createPayloads(self.scope.fs.io, directory, witnesses, &created);
        record.files = witnesses;
        try writeRecord(self.scope, self.allocator, directory, record);
        recorded = true;
        try writePayloads(self.scope.fs.io, directory, history.files.items, witnesses);
        record.phase = .ready;
        try writeRecord(self.scope, self.allocator, directory, record);
        _ = try self.reconcile(limits, false);
        const ready_bytes = try renderRecord(self.allocator, record);
        defer self.allocator.free(ready_bytes);
        self.ready_digest = try definition_core.canonical_json.digestBytesAlloc(
            self.allocator,
            ready_bytes,
        );
        record.phase = .installed;
        record.installed = true;
        self.installed_record = try renderRecord(self.allocator, record);
        self.scope.mutation_state = true;
    }

    pub fn publicationMutation(self: *const Workspace) !durable_store.TransactionMutation {
        return .{
            .path = "./" ++ record_path,
            .text = self.installed_record orelse return error.PreparationNotStaged,
            .expectation = .{
                .expected_exists = true,
                .expected_digest = self.ready_digest orelse return error.PreparationNotStaged,
            },
            .content_mode = .raw,
            .max_bytes = record_max_bytes,
        };
    }
};

fn prepareWitnesses(
    allocator: std.mem.Allocator,
    history: *const preparation.History,
    limits: preparation.Limits,
) ![]Witness {
    var total: usize = 0;
    const witnesses = try allocator.alloc(Witness, history.files.items.len);
    errdefer allocator.free(witnesses);
    for (history.files.items, witnesses) |file, *witness| {
        if (file.path.len == 0 or file.path.len > 4096) return error.InvalidPreparationPath;
        if (file.bytes.len > limits.max_bytes - total) return error.PreparationSpaceBoundExceeded;
        total += file.bytes.len;
        const digest = try definition_core.canonical_json.digestBytesAlloc(allocator, file.bytes);
        defer allocator.free(digest);
        if (!std.mem.eql(u8, digest, file.digest)) return error.PreparationDigestMismatch;
        witness.* = .{
            .path = file.path,
            .digest = file.digest,
            .length = file.bytes.len,
            .inode = 0,
        };
    }
    if (total != history.bytes) return error.PreparationSizeMismatch;
    return witnesses;
}

fn createPayloads(
    io: std.Io,
    directory: std.Io.Dir,
    witnesses: []Witness,
    created: *usize,
) !void {
    for (witnesses, 0..) |*witness, index| {
        var name_buffer: [40]u8 = undefined;
        const name = try payloadName(&name_buffer, index);
        const file = try directory.createFile(io, name, .{
            .exclusive = true,
            .read = true,
            .permissions = .fromMode(0o600),
        });
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file or stat.nlink != 1) return error.PreparationOwnershipUnknown;
        witness.inode = stat.inode;
        created.* += 1;
    }
}

fn writePayloads(
    io: std.Io,
    directory: std.Io.Dir,
    files: []const preparation.File,
    witnesses: []const Witness,
) !void {
    for (files, witnesses, 0..) |source, witness, index| {
        var name_buffer: [40]u8 = undefined;
        const name = try payloadName(&name_buffer, index);
        const file = try directory.openFile(io, name, .{
            .mode = .read_write,
            .follow_symlinks = false,
        });
        defer file.close(io);
        try checkWitness(try file.stat(io), witness);
        try file.writePositionalAll(io, source.bytes, 0);
        try file.sync(io);
    }
}

fn reportCleanupFailure(io: std.Io, action: []const u8, err: anyerror) void {
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);
    var buffer: [256]u8 = undefined;
    const stderr = (io.lockStderr(&buffer, null) catch return).terminal();
    defer io.unlockStderr();
    std.log.defaultLogFileTerminal(
        .warn,
        .default,
        "preparation cleanup could not {s}: {s}; retained work requires inspection",
        .{ action, @errorName(err) },
        stderr,
    ) catch return;
}

pub fn inspect(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    limits: preparation.Limits,
) !Report {
    var observation: ?Report = null;
    try inspectObserved(scope, allocator, limits, &observation);
    return observation.?;
}

pub fn inspectObserved(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    limits: preparation.Limits,
    observation: *?Report,
) !void {
    observation.* = null;
    if (!scope.fs.isPinned()) return error.PreparationRequiresManagedRoot;
    var guard = try durable_store.acquireCasReadLockPair(
        scope.fs,
        allocator,
        workspace_path,
        workspace_path,
    );
    defer guard.deinit();
    if (guard.count == 0 and try workspaceExists(scope)) return error.PreparationOwnershipUnknown;
    try reconcileLocked(scope, allocator, limits, false, observation);
}

fn reconcileLocked(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    limits: preparation.Limits,
    apply: bool,
    observation: *?Report,
) !void {
    try limits.validate();
    try durable_store.ensureNoPendingTransactions(scope.fs, allocator, ".transactions");
    if (!try workspaceExists(scope)) {
        observation.* = .{ .complete = true };
        return;
    }
    const record_bytes = scope.readFile(allocator, record_path, record_max_bytes) catch |err|
        switch (err) {
            error.FileNotFound => return error.PreparationOwnershipUnknown,
            else => return err,
        };
    defer allocator.free(record_bytes);
    const parsed = std.json.parseFromSlice(Record, allocator, record_bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.PreparationOwnershipUnknown;
    defer parsed.deinit();
    const record = parsed.value;
    try validateRecord(record, limits);
    observation.* = .{ .phase = record.phase, .installed = record.installed };
    const result = &observation.*.?;
    var directory = try scope.fs.directory().openDir(scope.fs.io, workspace_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer directory.close(scope.fs.io);
    try inspectPayloads(scope, allocator, directory, record, limits, result);
    if (!apply or record.phase == .finalized) {
        result.complete = true;
        return;
    }
    try durable_store.ensureNoPendingTransactions(scope.fs, allocator, ".transactions");
    result.activity = .cleanup;
    try releasePayloads(scope, directory, record.files, result);
    var finalized = record;
    finalized.phase = .finalized;
    finalized.files = &.{};
    try writeRecord(scope, allocator, directory, finalized);
    result.phase = .finalized;
    result.files = 0;
    result.bytes = 0;
    result.complete = true;
    scope.mutation_state = true;
}

fn inspectPayloads(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    record: Record,
    limits: preparation.Limits,
    result: *Report,
) !void {
    var iterator = directory.iterate();
    var entries: usize = 0;
    while (try iterator.next(scope.fs.io)) |entry| {
        entries += 1;
        if (entries > limits.max_files + 2) return error.PreparationFileBoundExceeded;
        if (entry.kind != .file) return error.PreparationOwnershipUnknown;
        if (std.mem.eql(u8, entry.name, "operation.json") or
            std.mem.eql(u8, entry.name, "operation.json.cas.lock.advisory")) continue;
        const index = payloadIndex(entry.name) orelse return error.PreparationOwnershipUnknown;
        if (index >= record.files.len) return error.PreparationOwnershipUnknown;
        const witness = record.files[index];
        const stat = try directory.statFile(scope.fs.io, entry.name, .{ .follow_symlinks = false });
        try checkWitness(stat, witness);
        if (record.phase != .capturing) {
            try verifyPayloadDigest(scope, allocator, entry.name, witness);
        }
        result.files += 1;
        result.bytes += @intCast(stat.size);
    }
}

fn verifyPayloadDigest(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    name: []const u8,
    witness: Witness,
) !void {
    const path = try std.fs.path.join(allocator, &.{ workspace_path, name });
    defer allocator.free(path);
    const bytes = try scope.readFile(allocator, path, witness.length);
    defer allocator.free(bytes);
    const digest = try definition_core.canonical_json.digestBytesAlloc(allocator, bytes);
    defer allocator.free(digest);
    if (bytes.len != witness.length or !std.mem.eql(u8, digest, witness.digest)) {
        return error.PreparationOwnershipUnknown;
    }
}

fn releasePayloads(
    scope: *storage_root.Scope,
    directory: std.Io.Dir,
    witnesses: []const Witness,
    result: *Report,
) !void {
    for (witnesses, 0..) |witness, index| {
        var name_buffer: [40]u8 = undefined;
        const name = try payloadName(&name_buffer, index);
        const stat = directory.statFile(scope.fs.io, name, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try checkWitness(stat, witness);
        const remaining_files = std.math.sub(usize, result.files, 1) catch
            return error.PreparationOwnershipUnknown;
        const remaining_bytes = std.math.sub(usize, result.bytes, @intCast(stat.size)) catch
            return error.PreparationOwnershipUnknown;
        if (scope.mutation_state != true) scope.mutation_state = null;
        try directory.deleteFile(scope.fs.io, name);
        scope.mutation_state = true;
        result.files = remaining_files;
        result.bytes = remaining_bytes;
        result.reclaimed_bytes += @intCast(stat.size);
    }
}

fn workspaceExists(scope: *storage_root.Scope) !bool {
    const stat = scope.fs.directory().statFile(scope.fs.io, workspace_path, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .directory) return error.PreparationOwnershipUnknown;
    return true;
}

fn validateRecord(record: Record, limits: preparation.Limits) !void {
    if (!std.mem.eql(u8, record.schema, record_schema) or record.phase == .absent or
        (record.phase == .installed and !record.installed) or
        (record.phase != .installed and record.phase != .finalized and record.installed) or
        (record.phase == .finalized and record.files.len != 0))
    {
        return error.PreparationOwnershipUnknown;
    }
    if (record.files.len > limits.max_files) return error.PreparationFileBoundExceeded;
    var total: usize = 0;
    for (record.files) |file| {
        if (file.path.len == 0 or file.path.len > 4096) return error.PreparationOwnershipUnknown;
        try definition_core.json.digest(file.digest);
        if (file.length > limits.max_bytes - total) return error.PreparationSpaceBoundExceeded;
        total += file.length;
    }
}

fn checkWitness(stat: std.Io.File.Stat, witness: Witness) !void {
    if (stat.kind != .file or stat.nlink != 1 or stat.inode != witness.inode or
        stat.size > witness.length) return error.PreparationOwnershipUnknown;
}

fn payloadName(buffer: []u8, index: usize) ![]const u8 {
    return std.fmt.bufPrint(buffer, "payload-{d}", .{index});
}

fn payloadIndex(name: []const u8) ?usize {
    if (!std.mem.startsWith(u8, name, "payload-")) return null;
    const number = name[8..];
    if (number.len == 0 or (number.len != 1 and number[0] == '0')) return null;
    for (number) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(usize, number, 10) catch null;
}

fn renderRecord(allocator: std.mem.Allocator, record: Record) ![]u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, record, .{});
    errdefer allocator.free(bytes);
    if (bytes.len > record_max_bytes) return error.PreparationMetadataBoundExceeded;
    return bytes;
}

fn writeRecord(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    record: Record,
) !void {
    const bytes = try renderRecord(allocator, record);
    defer allocator.free(bytes);
    const outcome = durable_store.publishReplacement(
        scope.fs.io,
        directory,
        directory,
        "operation.json",
        &.{bytes},
        .{
            .permissions = .fromMode(0o600),
            .durability = .file_and_directories_synced,
        },
    );
    switch (outcome) {
        .complete => {},
        .not_published, .publication_unknown => |failure| return failure.cause,
        .published_unsynced => |err| return err,
    }
}

fn testHistory() !preparation.History {
    const allocator = std.testing.allocator;
    var history: preparation.History = .{ .exists = true, .records = 1 };
    errdefer history.deinit(allocator);
    const bytes = try allocator.dupe(u8, "{\"record\":1}\n");
    errdefer allocator.free(bytes);
    const path = try allocator.dupe(u8, "selected.jsonl");
    errdefer allocator.free(path);
    const digest = try definition_core.canonical_json.digestBytesAlloc(allocator, bytes);
    errdefer allocator.free(digest);
    try history.files.append(allocator, .{ .path = path, .bytes = bytes, .digest = digest });
    history.bytes = bytes.len;
    return history;
}

test "preparation work discards owned interrupted capture without native dependency" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scope = storage_root.Scope.init(.anchored(std.testing.io, temporary.dir));
    var workspace = try Workspace.acquire(&scope, allocator);
    defer workspace.deinit();
    var history = try testHistory();
    defer history.deinit(allocator);
    try workspace.stage(&history, "{}", .{});
    const bytes = try scope.readFile(allocator, record_path, record_max_bytes);
    defer allocator.free(bytes);
    var record = try std.json.parseFromSlice(Record, allocator, bytes, .{});
    defer record.deinit();
    record.value.phase = .capturing;
    var directory = try temporary.dir.openDir(std.testing.io, workspace_path, .{});
    defer directory.close(std.testing.io);
    try writeRecord(&scope, allocator, directory, record.value);
    try directory.writeFile(std.testing.io, .{ .sub_path = "payload-0", .data = "{" });
    const report = try workspace.reconcile(.{}, true);
    try std.testing.expectEqual(Phase.finalized, report.phase);
    try std.testing.expectEqual(@as(usize, 1), report.reclaimed_bytes);
    try std.testing.expect(!durable_store.fileExists(scope.fs, ".preparation/payload-0"));
    try std.testing.expect(durable_store.fileExists(scope.fs, record_path));
    try std.testing.expect(durable_store.fileExists(scope.fs, ".preparation.cas.lock.advisory"));
}

test "preparation work finalizes after native installation and retains native evidence" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scope = storage_root.Scope.init(.anchored(std.testing.io, temporary.dir));
    var workspace = try Workspace.acquire(&scope, allocator);
    defer workspace.deinit();
    var history = try testHistory();
    defer history.deinit(allocator);
    try workspace.stage(&history, "{\"sources\":[\"fixture\"]}", .{});
    const mutations = [_]durable_store.TransactionMutation{
        .{
            .path = "./selected.jsonl",
            .text = history.files.items[0].bytes,
            .expectation = .{ .expected_exists = false },
            .content_mode = .raw,
        },
        try workspace.publicationMutation(),
    };
    const receipt = try durable_store.commitTextTransaction(
        scope.fs,
        allocator,
        "./.transactions",
        &mutations,
        .{
            .owner = .{ .process_id = 0, .session_id = "preparation-test", .executor = "ledger" },
            .fencing_counter_path = "./.fencing.counter",
            .reject_symlinks = true,
        },
    );
    defer receipt.deinit(allocator);
    const report = try workspace.reconcile(.{}, true);
    try std.testing.expectEqual(Phase.finalized, report.phase);
    try std.testing.expect(report.installed);
    try std.testing.expectEqual(history.bytes, report.reclaimed_bytes);
    try std.testing.expect(durable_store.fileExists(scope.fs, receipt.record_path));
    try std.testing.expect(durable_store.fileExists(scope.fs, receipt.commit_marker_path));
    try std.testing.expect(durable_store.fileExists(
        scope.fs,
        ".preparation/operation.json.cas.lock.advisory",
    ));
    const installed = try scope.readFile(allocator, "selected.jsonl", 1024);
    defer allocator.free(installed);
    try std.testing.expectEqualStrings(history.files.items[0].bytes, installed);
    const again = try workspace.reconcile(.{}, true);
    try std.testing.expect(again.installed);
    try std.testing.expectEqual(@as(usize, 0), again.reclaimed_bytes);
}

test "preparation work retains payload while native publication remains unresolved" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scope = storage_root.Scope.init(.anchored(std.testing.io, temporary.dir));
    var workspace = try Workspace.acquire(&scope, allocator);
    defer workspace.deinit();
    var history = try testHistory();
    defer history.deinit(allocator);
    try workspace.stage(&history, "{}", .{});
    try temporary.dir.createDirPath(std.testing.io, ".transactions/unresolved");
    try std.testing.expectError(error.TransactionRecoveryRequired, workspace.reconcile(.{}, true));
    try std.testing.expectError(error.TransactionRecoveryRequired, workspace.reconcile(.{}, false));
    const retained = try scope.readFile(allocator, ".preparation/payload-0", 1024);
    defer allocator.free(retained);
    try std.testing.expectEqualStrings(history.files.items[0].bytes, retained);
    try std.testing.expect(durable_store.fileExists(scope.fs, record_path));
}

test "preparation work retains unknown artifacts and refuses an unguarded workspace" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scope = storage_root.Scope.init(.anchored(std.testing.io, temporary.dir));
    try std.testing.expectEqual(Phase.absent, (try inspect(&scope, allocator, .{})).phase);
    try std.testing.expect(!durable_store.fileExists(scope.fs, ".preparation.cas.lock.advisory"));
    try temporary.dir.createDirPath(std.testing.io, workspace_path);
    try std.testing.expectError(error.PreparationOwnershipUnknown, inspect(&scope, allocator, .{}));
    try temporary.dir.deleteDir(std.testing.io, workspace_path);
    var workspace = try Workspace.acquire(&scope, allocator);
    defer workspace.deinit();
    var history = try testHistory();
    defer history.deinit(allocator);
    try workspace.stage(&history, "{}", .{});
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".preparation/foreign",
        .data = "keep",
    });
    try std.testing.expectError(error.PreparationOwnershipUnknown, workspace.reconcile(.{}, true));
    try std.testing.expect(durable_store.fileExists(scope.fs, ".preparation/payload-0"));
    const foreign = try scope.readFile(allocator, ".preparation/foreign", 1024);
    defer allocator.free(foreign);
    try std.testing.expectEqualStrings("keep", foreign);
}

test "preparation work keeps one bounded workspace across one hundred retries" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scope = storage_root.Scope.init(.anchored(std.testing.io, temporary.dir));
    var history = try testHistory();
    defer history.deinit(allocator);
    for (0..100) |_| {
        var workspace = try Workspace.acquire(&scope, allocator);
        defer workspace.deinit();
        try workspace.stage(&history, "{}", .{});
        const retained = try workspace.reconcile(.{}, false);
        try std.testing.expectEqual(history.bytes, retained.bytes);
        try std.testing.expectEqual(@as(usize, 1), retained.files);
        const released = try workspace.reconcile(.{}, true);
        try std.testing.expectEqual(history.bytes, released.reclaimed_bytes);
    }
    var directory = try temporary.dir.openDir(std.testing.io, workspace_path, .{ .iterate = true });
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    const entry = (try iterator.next(std.testing.io)).?;
    try std.testing.expectEqualStrings("operation.json", entry.name);
    try std.testing.expectEqual(null, try iterator.next(std.testing.io));
    const report = try inspect(&scope, allocator, .{});
    try std.testing.expectEqual(Phase.finalized, report.phase);
    try std.testing.expectEqual(@as(usize, 0), report.bytes);
}
