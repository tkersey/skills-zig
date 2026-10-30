const std = @import("std");
const durable_store = @import("durable_store");
const storage_root = @import("storage_root");
const sources = @import("storage_sources.zig");
const storage_capture = @import("storage_capture.zig");

pub const Limits = struct {
    sources: sources.Limits = .{},
    evidence_bytes: usize,
};

pub const Evidence = struct {
    observation: sources.Observation,
    subject: sources.Subject,
    bytes: []const u8,
};

pub const RootAdmission = struct {
    plan: sources.Plan,
    root: storage_root.SourceRoot,
    arena: std.heap.ArenaAllocator,
    evidence: []const Evidence,
    evidence_bytes_read: usize,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        supplied: sources.Source,
        limits: Limits,
    ) !RootAdmission {
        const encoded = try sources.encode(allocator, &.{supplied}, limits.sources);
        defer allocator.free(encoded);
        var plan = try sources.parseWithLimits(allocator, encoded, limits.sources);
        errdefer plan.deinit();
        const source = plan.sources[0];
        if (source.kind == .@"preservation-bundle") return error.UnsupportedSourceAdmissionKind;
        try (sources.Subject{
            .source_id = source.source_id,
            .kind = source.kind,
            .locator = source.locator,
            .store_id = source.store_id,
        }).validate();
        var root = try storage_root.SourceRoot.open(allocator, io, source.locator, source.store_id);
        errdefer root.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var reader: EvidenceReader = .{
            .allocator = arena.allocator(),
            .scratch = allocator,
            .root = &root,
            .source = source,
            .remaining = limits.evidence_bytes,
        };
        const evidence = try arena.allocator().alloc(Evidence, source.observations.len);
        for (source.observations, evidence) |observation, *item| {
            item.* = try reader.read(observation);
        }
        try root.revalidateControl();
        return .{
            .plan = plan,
            .root = root,
            .arena = arena,
            .evidence = evidence,
            .evidence_bytes_read = limits.evidence_bytes - reader.remaining,
        };
    }

    pub fn deinit(self: *RootAdmission) void {
        self.arena.deinit();
        self.root.deinit();
        self.plan.deinit();
        self.* = undefined;
    }

    pub fn revalidate(self: *const RootAdmission) !void {
        try self.root.revalidateControl();
        for (self.evidence) |item| try self.root.revalidate(item.subject.locator);
    }

    pub fn descriptor(self: *const RootAdmission) sources.Source {
        return self.plan.sources[0];
    }

    pub fn requireSource(self: *const RootAdmission, source: *const storage_root.SourceRoot) !void {
        try self.revalidate();
        try source.revalidateControl();
        const expected = try durable_store.openDirectoryIdentity(self.root.io, self.root.directory);
        const actual = try durable_store.openDirectoryIdentity(source.io, source.directory);
        if (!std.meta.eql(expected, actual)) return error.SourceAdmissionMismatch;
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    source: sources.Source,
    bytes: []const u8,
    other: []const u8,

    fn init(managed: bool) !Fixture {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        try tmp.dir.createDir(io, "source", .default_dir);
        try tmp.dir.createDir(io, "other", .default_dir);
        const root = try tmp.dir.realPathFileAlloc(io, "source", owned);
        const other = try tmp.dir.realPathFileAlloc(io, "other", owned);
        const evidence = try tmp.dir.realPathFileAlloc(io, ".", owned);
        const path = try std.fs.path.join(owned, &.{ evidence, "registration.json" });
        const bytes = try std.json.Stringify.valueAlloc(owned, .{
            .source_id = "original-source",
            .store_root = root,
            .store_id = if (managed) "store-a" else @as(?[]const u8, null),
        }, .{});
        try tmp.dir.writeFile(io, .{ .sub_path = "registration.json", .data = bytes });
        if (managed) try initializeManagedRoot(tmp.dir);
        const observations = try owned.alloc(sources.Observation, 1);
        observations[0] = .{
            .observation_id = "original-observation",
            .evidence_locator = path,
            .evidence_digest = try @import("definition_core").canonical_json.digestBytesAlloc(
                owned,
                bytes,
            ),
            .evidence_pointer = "",
            .binding = .{
                .root_pointer = "/store_root",
                .source_id_pointer = "/source_id",
                .store_id_pointer = if (managed) "/store_id" else null,
            },
        };
        return .{
            .tmp = tmp,
            .arena = arena,
            .source = .{
                .source_id = "original-source",
                .kind = if (managed) .@"managed-root" else .@"unmanaged-root",
                .locator = root,
                .store_id = if (managed) "store-a" else null,
                .observations = observations,
            },
            .bytes = bytes,
            .other = other,
        };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }
};

fn initializeManagedRoot(directory: std.Io.Dir) !void {
    const io = std.testing.io;
    try directory.createDir(io, "source/.ledger", .default_dir);
    try directory.writeFile(io, .{
        .sub_path = "source/.ledger-root.json",
        .data = "{\"schema\":\"ledger-storage-root/v1\",\"store_id\":\"store-a\"}",
    });
}

test "source admission binds generic registration claims to the actual root without writes" {
    for ([_]bool{ false, true }) |managed| {
        var fixture = try Fixture.init(managed);
        defer fixture.deinit();
        var admitted = try RootAdmission.open(
            std.testing.allocator,
            std.testing.io,
            fixture.source,
            .{ .evidence_bytes = fixture.bytes.len },
        );
        defer admitted.deinit();
        try std.testing.expectEqual(fixture.bytes.len, admitted.evidence_bytes_read);
        try std.testing.expectEqualStrings(fixture.bytes, admitted.evidence[0].bytes);
        try std.testing.expectEqualStrings(
            fixture.source.locator,
            admitted.evidence[0].subject.locator,
        );
        try admitted.revalidate();
        if (!managed) {
            try std.testing.expect(admitted.root.control == null);
            try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.openDir(
                std.testing.io,
                "source/.ledger",
                .{},
            ));
        }
    }
}

test "source admission rejects unrelated root and source identity despite valid evidence digest" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var other = fixture.source;
    other.locator = fixture.other;
    try std.testing.expectError(error.PreparationSourceChanged, RootAdmission.open(
        std.testing.allocator,
        std.testing.io,
        other,
        .{ .evidence_bytes = fixture.bytes.len },
    ));
    other = fixture.source;
    other.source_id = "different-source";
    try std.testing.expectError(error.SourceEvidenceSourceIdentityMismatch, RootAdmission.open(
        std.testing.allocator,
        std.testing.io,
        other,
        .{ .evidence_bytes = fixture.bytes.len },
    ));
}

test "source admission counts shared evidence once and enforces exact aggregate limit" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var observations: [2]sources.Observation = @splat(fixture.source.observations[0]);
    observations[1].observation_id = "distinct-original-observation";
    var descriptor = fixture.source;
    descriptor.observations = &observations;
    var admitted = try RootAdmission.open(std.testing.allocator, std.testing.io, descriptor, .{
        .evidence_bytes = fixture.bytes.len,
    });
    defer admitted.deinit();
    try std.testing.expectEqual(@as(usize, 2), admitted.evidence.len);
    try std.testing.expectEqual(fixture.bytes.len, admitted.evidence_bytes_read);
    try std.testing.expect(admitted.evidence[0].bytes.ptr == admitted.evidence[1].bytes.ptr);
    try std.testing.expectError(error.SourceEvidenceLimitExceeded, RootAdmission.open(
        std.testing.allocator,
        std.testing.io,
        descriptor,
        .{ .evidence_bytes = fixture.bytes.len - 1 },
    ));
}

test "source admission retains original evidence but rejects replaced live root" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var admitted = try RootAdmission.open(std.testing.allocator, std.testing.io, fixture.source, .{
        .evidence_bytes = fixture.bytes.len,
    });
    defer admitted.deinit();
    const io = std.testing.io;
    try fixture.tmp.dir.rename("source", fixture.tmp.dir, "moved", io);
    try fixture.tmp.dir.createDir(io, "source", .default_dir);
    try std.testing.expectError(error.PreparationSourceChanged, admitted.revalidate());
    try fixture.tmp.dir.deleteFile(io, "registration.json");
    const retained = admitted.evidence[0];
    try sources.verifyBoundObservationEvidence(
        std.testing.allocator,
        retained.observation,
        retained.subject,
        retained.bytes,
    );
}

const EvidenceReader = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    root: *const storage_root.SourceRoot,
    source: sources.Source,
    remaining: usize,
    by_locator: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn read(self: *EvidenceReader, observation: sources.Observation) !Evidence {
        const bytes = self.by_locator.get(observation.evidence_locator) orelse bytes: {
            const content = try self.capture(observation.evidence_locator);
            try self.by_locator.put(self.allocator, observation.evidence_locator, content);
            break :bytes content;
        };
        var claims = try sources.readObservationClaims(self.scratch, observation, bytes);
        defer claims.deinit();
        const subject: sources.Subject = .{
            .source_id = self.source.source_id,
            .kind = self.source.kind,
            .locator = try self.allocator.dupe(u8, claims.locator),
            .store_id = self.source.store_id,
        };
        try sources.verifyBoundObservationEvidence(self.scratch, observation, subject, bytes);
        try self.root.revalidate(subject.locator);
        return .{ .observation = observation, .subject = subject, .bytes = bytes };
    }

    fn capture(self: *EvidenceReader, locator: []const u8) ![]const u8 {
        const io = self.root.io;
        const file = try durable_store.openRegularFileNoSymlink(.init(io, .cwd()), locator);
        defer file.close(io);
        const maximum = @min(self.remaining, sources.max_manifest_bytes);
        if ((try file.stat(io)).size > maximum) return error.SourceEvidenceLimitExceeded;
        var reader = file.reader(io, &.{});
        var output = std.Io.Writer.Allocating.init(self.scratch);
        defer output.deinit();
        var buffer: [8192]u8 = undefined;
        const result = storage_capture.copy(
            &reader.interface,
            &output.writer,
            maximum,
            &buffer,
        ) catch |err| {
            if (err == error.CaptureLimitExceeded) return error.SourceEvidenceLimitExceeded;
            return err;
        };
        self.remaining -= @intCast(result.bytes);
        return self.allocator.dupe(u8, output.written());
    }
};
