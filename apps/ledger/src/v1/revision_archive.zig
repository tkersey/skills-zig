const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");

pub const Candidate = struct {
    path: []u8,
    exists: bool,

    pub fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub fn prepare(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    revision: []const u8,
    content: []const u8,
    max_bytes: usize,
) !Candidate {
    if (!std.fs.path.isAbsolute(repo_root)) {
        return error.RepositoryRootNotAbsolute;
    }
    if (content.len > max_bytes) return error.RevisionArchiveTooLarge;
    try definition_core.json.digest(revision);
    const actual = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        content,
    );
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, revision)) {
        return error.RevisionArchiveDigestMismatch;
    }
    const path = try pathAlloc(allocator, repo_root, revision);
    errdefer allocator.free(path);
    try durable_store.rejectSymlinkComponents(path);
    const existing = durable_store.readRegularFileNoSymlink(
        allocator,
        path,
        max_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{
            .path = path,
            .exists = false,
        },
        else => return err,
    };
    defer allocator.free(existing);
    if (!std.mem.eql(u8, existing, content)) {
        return error.RevisionArchiveCollision;
    }
    return .{
        .path = path,
        .exists = true,
    };
}

pub fn load(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    revision: []const u8,
    max_bytes: usize,
) ![]u8 {
    if (!std.fs.path.isAbsolute(repo_root)) {
        return error.RepositoryRootNotAbsolute;
    }
    try definition_core.json.digest(revision);
    const path = try pathAlloc(allocator, repo_root, revision);
    defer allocator.free(path);
    const content = durable_store.readRegularFileNoSymlink(
        allocator,
        path,
        max_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.RevisionArchiveMissing,
        else => return err,
    };
    errdefer allocator.free(content);
    const actual = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        content,
    );
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, revision)) {
        return error.RevisionArchiveDigestMismatch;
    }
    return content;
}

pub fn pathAlloc(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    revision: []const u8,
) ![]u8 {
    try definition_core.json.digest(revision);
    const file_name = try std.fmt.allocPrint(
        allocator,
        "{s}.bin",
        .{revision[7..]},
    );
    defer allocator.free(file_name);
    return std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", ".revisions", file_name },
    );
}

test "revision archive is immutable and content addressed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const archive_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".ledger", ".revisions" },
    );
    defer std.testing.allocator.free(archive_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(archive_dir);
    const content = "{\"value\":1}";
    const revision = try definition_core.canonical_json.digestBytesAlloc(
        std.testing.allocator,
        content,
    );
    defer std.testing.allocator.free(revision);
    var candidate = try prepare(
        std.testing.allocator,
        root,
        revision,
        content,
        4096,
    );
    defer candidate.deinit(std.testing.allocator);
    try std.testing.expect(!candidate.exists);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        candidate.path,
        content,
    );
    var existing = try prepare(
        std.testing.allocator,
        root,
        revision,
        content,
        4096,
    );
    defer existing.deinit(std.testing.allocator);
    try std.testing.expect(existing.exists);
    const loaded = try load(
        std.testing.allocator,
        root,
        revision,
        4096,
    );
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualStrings(content, loaded);
}
