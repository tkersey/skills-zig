const std = @import("std");
const storage_root = @import("storage_root");
const durable_store = @import("durable_store");
const definition_core = @import("definition_core");
const preparation = @import("preparation.zig");

pub const workspace_path = ".preparation";
pub const record_path = ".preparation.json";
pub const record_max_bytes: usize = 1024 * 1024;
pub const provenance_max_bytes: usize = 64 * 1024;
const record_schema = "ledger-preparation/v1";
pub const Phase = enum { absent, installed, finalized };

pub const Report = struct {
    phase: Phase = .absent,
    installed: bool = false,
    observed_by: enum { inspection, reconciliation } = .inspection,
    activity: enum { inspection, cleanup } = .inspection,
    complete: bool = false,
    files: usize = 0,
    bytes: u64 = 0,
    reclaimed_bytes: ?u64 = 0,
};

const Witness = struct { path: []const u8, digest: []const u8, length: usize };
const Record = struct {
    schema: []const u8 = record_schema,
    files: []const Witness,
    provenance: std.json.Value,
};

pub const Workspace = struct {
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    guard: std.Io.File,
    before_digest: ?[]u8 = null,
    installed_record: ?[]u8 = null,

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
        if (self.before_digest) |value| self.allocator.free(value);
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
        if (self.installed_record != null) return error.PreparationAlreadyStaged;
        if (history.files.items.len == 0 or history.files.items.len > limits.max_files) {
            return error.PreparationFileBoundExceeded;
        }
        if (provenance_json.len > provenance_max_bytes) {
            return error.PreparationMetadataBoundExceeded;
        }
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            provenance_json,
            .{ .duplicate_field_behavior = .@"error" },
        );
        defer parsed.deinit();
        const witnesses = try self.allocator.alloc(Witness, history.files.items.len);
        defer self.allocator.free(witnesses);
        var total: usize = 0;
        for (history.files.items, witnesses) |file, *witness| {
            if (file.bytes.len > limits.max_bytes - total) {
                return error.PreparationSpaceBoundExceeded;
            }
            total += file.bytes.len;
            witness.* = .{ .path = file.path, .digest = file.digest, .length = file.bytes.len };
        }
        if (total != history.bytes) return error.PreparationSizeMismatch;
        const record: Record = .{ .files = witnesses, .provenance = parsed.value };
        try validateRecord(record);
        const previous = self.scope.readFile(
            self.allocator,
            record_path,
            record_max_bytes,
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (previous) |bytes| self.allocator.free(bytes);
        if (previous) |bytes| {
            self.before_digest = try definition_core.canonical_json.digestBytesAlloc(
                self.allocator,
                bytes,
            );
        }
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, record, .{});
        errdefer self.allocator.free(bytes);
        if (bytes.len > record_max_bytes) return error.PreparationMetadataBoundExceeded;
        self.installed_record = bytes;
    }

    pub fn publicationMutation(self: *const Workspace) !durable_store.TransactionMutation {
        return .{
            .path = "./" ++ record_path,
            .text = self.installed_record orelse return error.PreparationNotStaged,
            .expectation = .{
                .expected_exists = self.before_digest != null,
                .expected_digest = self.before_digest,
            },
            .content_mode = .raw,
            .max_bytes = record_max_bytes,
        };
    }
};

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
    try rejectLegacyWorkspace(scope);
    try durable_store.ensureNoPendingTransactions(scope.fs, allocator, ".transactions");
    const bytes = scope.readFile(allocator, record_path, record_max_bytes) catch |err|
        switch (err) {
            error.FileNotFound => {
                observation.* = .{ .complete = true };
                return;
            },
            else => return err,
        };
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Record, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    try validateRecord(parsed.value);
    observation.* = .{ .phase = .finalized, .installed = true };
    const report = &observation.*.?;
    _ = apply;
    report.complete = true;
}

fn rejectLegacyWorkspace(scope: *storage_root.Scope) !void {
    _ = scope.fs.directory().statFile(scope.fs.io, workspace_path, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.PreparationOwnershipUnknown;
}

fn validateRecord(record: Record) !void {
    if (!std.mem.eql(u8, record.schema, record_schema)) return error.PreparationOwnershipUnknown;
    if (record.files.len == 0) return error.PreparationOwnershipUnknown;
    for (record.files) |file| {
        if (file.path.len == 0 or file.path.len > 4096) return error.PreparationOwnershipUnknown;
        try definition_core.json.digest(file.digest);
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

test "preparation capture owns no duplicate payload before native publication" {
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
        try std.testing.expectEqual(Phase.absent, (try workspace.reconcile(.{}, false)).phase);
        try std.testing.expect(!durable_store.fileExists(scope.fs, workspace_path));
        try std.testing.expect(!durable_store.fileExists(scope.fs, record_path));
    }
}

test "native publication leaves no duplicate preparation payload and preserves audit" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scope = storage_root.Scope.init(.anchored(std.testing.io, temporary.dir));
    var workspace = try Workspace.acquire(&scope, allocator);
    defer workspace.deinit();
    var history = try testHistory();
    defer history.deinit(allocator);
    try std.testing.expectError(
        error.PreparationSpaceBoundExceeded,
        workspace.stage(&history, "{}", .{ .max_bytes = 1 }),
    );
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
    const observed = try workspace.reconcile(.{ .max_bytes = 1, .max_files = 2 }, false);
    try std.testing.expectEqual(Phase.finalized, observed.phase);
    try std.testing.expect(observed.installed and observed.bytes == 0);
    const finalized = try workspace.reconcile(.{}, true);
    try std.testing.expectEqual(Phase.finalized, finalized.phase);
    try std.testing.expectEqual(@as(?u64, 0), finalized.reclaimed_bytes);
    try std.testing.expect(durable_store.fileExists(scope.fs, receipt.record_path));
    try std.testing.expect(durable_store.fileExists(scope.fs, receipt.commit_marker_path));
    try std.testing.expect(durable_store.fileExists(scope.fs, record_path));
    try std.testing.expect(durable_store.fileExists(scope.fs, ".preparation.cas.lock.advisory"));
    const installed = try scope.readFile(allocator, "selected.jsonl", 1024);
    defer allocator.free(installed);
    try std.testing.expectEqualStrings(history.files.items[0].bytes, installed);
    const again = try workspace.reconcile(.{}, true);
    try std.testing.expect(again.installed and again.complete);
    try std.testing.expectEqual(@as(?u64, 0), again.reclaimed_bytes);
}

test "preparation retains unknown old work and unresolved native publication" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scope = storage_root.Scope.init(.anchored(std.testing.io, temporary.dir));
    try std.testing.expectEqual(Phase.absent, (try inspect(&scope, allocator, .{})).phase);
    try std.testing.expect(!durable_store.fileExists(scope.fs, ".preparation.cas.lock.advisory"));
    try temporary.dir.createDirPath(std.testing.io, workspace_path);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".preparation/foreign",
        .data = "keep",
    });
    try std.testing.expectError(error.PreparationOwnershipUnknown, inspect(&scope, allocator, .{}));
    const retained = try scope.readFile(allocator, ".preparation/foreign", 1024);
    defer allocator.free(retained);
    try std.testing.expectEqualStrings("keep", retained);
    try temporary.dir.deleteFile(std.testing.io, ".preparation/foreign");
    try temporary.dir.deleteDir(std.testing.io, workspace_path);
    try temporary.dir.createDirPath(std.testing.io, ".transactions/unresolved");
    try std.testing.expectError(error.TransactionRecoveryRequired, inspect(&scope, allocator, .{}));
    try std.testing.expect(durable_store.fileExists(scope.fs, ".transactions/unresolved"));
}
