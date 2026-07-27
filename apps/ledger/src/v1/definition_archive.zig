const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const definition = @import("definition.zig");

pub const schema = "ledger-definition-archive/v1";
pub const max_bytes: usize = 8 * 1024 * 1024;

pub const Candidate = struct {
    path: []u8,
    content: []u8,
    exists: bool,

    pub fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const Loaded = struct {
    definition_id: []u8,
    entry_path: []u8,
    closure: definition_core.Closure,

    pub fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        allocator.free(self.definition_id);
        allocator.free(self.entry_path);
        self.closure.deinit(allocator);
        self.* = undefined;
    }
};

pub fn prepare(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    entry_path: []const u8,
    closure: *const definition_core.Closure,
) !Candidate {
    if (!std.fs.path.isAbsolute(repo_root)) return error.RepositoryRootNotAbsolute;
    if (closure.find(entry_path) == null) return error.EntryDefinitionMissing;
    const path = try pathAlloc(allocator, repo_root, closure.digestSlice());
    errdefer allocator.free(path);
    const content = try renderAlloc(
        allocator,
        definition_id,
        entry_path,
        closure,
    );
    errdefer allocator.free(content);
    try durable_store.rejectSymlinkComponents(path);
    const existing = durable_store.readRegularFileNoSymlink(
        allocator,
        path,
        max_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |bytes| allocator.free(bytes);
    if (existing) |bytes| {
        if (!std.mem.eql(u8, bytes, content)) {
            return error.DefinitionArchiveConflict;
        }
    }
    return .{
        .path = path,
        .content = content,
        .exists = existing != null,
    };
}

pub fn pathAlloc(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    digest: []const u8,
) ![]u8 {
    try definition_core.json.digest(digest);
    const name = try std.fmt.allocPrint(allocator, "{s}.json", .{digest[7..]});
    defer allocator.free(name);
    return std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", ".definitions", name },
    );
}

pub fn load(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    expected_digest: []const u8,
) !Loaded {
    const path = try pathAlloc(allocator, repo_root, expected_digest);
    defer allocator.free(path);
    try durable_store.rejectSymlinkComponents(path);
    const bytes = try durable_store.readRegularFileNoSymlink(
        allocator,
        path,
        max_bytes,
    );
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    ) catch return error.InvalidDefinitionArchive;
    defer parsed.deinit();
    const object = try definition_core.json.object(parsed.value);
    const header = try archiveHeader(object, expected_digest);
    var closure = try archiveClosure(
        allocator,
        object,
        header.entry_path,
        expected_digest,
    );
    errdefer closure.deinit(allocator);
    const owned_definition_id = try allocator.dupe(u8, header.definition_id);
    errdefer allocator.free(owned_definition_id);
    const owned_entry_path = try allocator.dupe(u8, header.entry_path);
    return .{
        .definition_id = owned_definition_id,
        .entry_path = owned_entry_path,
        .closure = closure,
    };
}

const ArchiveHeader = struct {
    definition_id: []const u8,
    entry_path: []const u8,
};

fn archiveHeader(
    object: std.json.ObjectMap,
    expected_digest: []const u8,
) !ArchiveHeader {
    try definition_core.json.requireExactKeys(object, &.{
        "abi",
        "definition_digest",
        "definition_id",
        "entry_path",
        "files",
        "schema",
    });
    try definition_core.json.requireFields(object, &.{
        "abi",
        "definition_digest",
        "definition_id",
        "entry_path",
        "files",
        "schema",
    });
    if (!std.mem.eql(
        u8,
        try definition_core.json.requiredString(object, "schema"),
        schema,
    )) return error.InvalidDefinitionArchiveSchema;
    if (!std.mem.eql(
        u8,
        try definition_core.json.requiredString(object, "abi"),
        definition.abi,
    )) return error.IncompatibleDefinitionArchiveAbi;
    const recorded_digest = try definition_core.json.requiredString(
        object,
        "definition_digest",
    );
    try definition_core.json.digest(recorded_digest);
    if (!std.mem.eql(u8, recorded_digest, expected_digest)) {
        return error.DefinitionArchiveDigestMismatch;
    }
    const definition_id = try definition_core.json.requiredString(
        object,
        "definition_id",
    );
    try definition_core.json.safeIdentifier(definition_id, 256);
    const entry_path = try definition_core.json.requiredString(
        object,
        "entry_path",
    );
    return .{
        .definition_id = definition_id,
        .entry_path = entry_path,
    };
}

fn archiveClosure(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    entry_path: []const u8,
    expected_digest: []const u8,
) !definition_core.Closure {
    const files = try archiveFiles(allocator, object);
    defer freeArchiveFiles(allocator, files);
    var closure = try definition_core.closure.fromCanonicalFiles(
        allocator,
        files,
        entry_path,
        .{},
    );
    errdefer closure.deinit(allocator);
    if (!std.mem.eql(u8, closure.digestSlice(), expected_digest)) {
        return error.DefinitionArchiveDigestMismatch;
    }
    return closure;
}

fn archiveFiles(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) ![]definition_core.ClosureFile {
    const values = try definition_core.json.array(
        try definition_core.json.field(object, "files"),
    );
    if (values.items.len == 0 or values.items.len > 128) {
        return error.InvalidDefinitionArchiveFileCount;
    }
    const files = try allocator.alloc(
        definition_core.ClosureFile,
        values.items.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |file| {
            allocator.free(file.path);
            allocator.free(file.canonical_json);
        }
        allocator.free(files);
    }
    for (values.items, 0..) |value, index| {
        const file = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(file, &.{ "content", "path" });
        try definition_core.json.requireFields(file, &.{ "content", "path" });
        const content = try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            try definition_core.json.field(file, "content"),
        );
        errdefer allocator.free(content);
        files[index] = .{
            .path = try allocator.dupe(
                u8,
                try definition_core.json.requiredString(file, "path"),
            ),
            .canonical_json = content,
        };
        initialized += 1;
    }
    return files;
}

fn freeArchiveFiles(
    allocator: std.mem.Allocator,
    files: []definition_core.ClosureFile,
) void {
    for (files) |file| {
        allocator.free(file.path);
        allocator.free(file.canonical_json);
    }
    allocator.free(files);
}

pub fn renderAlloc(
    allocator: std.mem.Allocator,
    definition_id: []const u8,
    entry_path: []const u8,
    closure: *const definition_core.Closure,
) ![]u8 {
    try definition_core.json.safeIdentifier(definition_id, 256);
    try definition_core.json.repositoryRelativePath(entry_path, false);
    if (!std.mem.endsWith(u8, entry_path, ".json")) {
        return error.DefinitionPathNotJson;
    }
    if (closure.find(entry_path) == null) return error.EntryDefinitionMissing;
    const recomputed_digest = definition_core.closure.digestFiles(closure.files);
    if (!std.mem.eql(
        u8,
        recomputed_digest[0..],
        closure.digestSlice(),
    )) return error.DefinitionClosureDigestMismatch;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(
        "{\"abi\":\"ledger-artifact-abi/v1\",\"definition_digest\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        closure.digestSlice(),
    );
    try output.writer.writeAll(",\"definition_id\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        definition_id,
    );
    try output.writer.writeAll(",\"entry_path\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        entry_path,
    );
    try output.writer.writeAll(",\"files\":[");
    for (closure.files, 0..) |file, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.writeAll("{\"content\":");
        try output.writer.writeAll(file.canonical_json);
        try output.writer.writeAll(",\"path\":");
        try definition_core.canonical_json.writeCanonicalString(
            &output.writer,
            file.path,
        );
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("],\"schema\":\"");
    try output.writer.writeAll(schema);
    try output.writer.writeAll("\"}\n");
    if (output.written().len > max_bytes) {
        return error.DefinitionArchiveTooLarge;
    }
    return output.toOwnedSlice();
}

test "definition archive is deterministic and content addressed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "child.json",
        .data = "{\"value\":1}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "root.json",
        .data = "{\"imports\":[\"child.json\"],\"value\":2}",
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "root.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    const first = try renderAlloc(
        std.testing.allocator,
        "example/archive",
        "root.json",
        &closure,
    );
    defer std.testing.allocator.free(first);
    const second = try renderAlloc(
        std.testing.allocator,
        "example/archive",
        "root.json",
        &closure,
    );
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(
        std.mem.indexOf(u8, first, closure.digestSlice()) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, first, "\"content\":{\"value\":1}") != null,
    );

    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    const path = try pathAlloc(
        std.testing.allocator,
        repo_root,
        closure.digestSlice(),
    );
    defer std.testing.allocator.free(path);
    try durable_store.writeTextAtomic(std.testing.allocator, path, first);
    var loaded = try load(
        std.testing.allocator,
        repo_root,
        closure.digestSlice(),
    );
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        closure.digestSlice(),
        loaded.closure.digestSlice(),
    );
    try std.testing.expectEqualStrings("root.json", loaded.entry_path);
    try std.testing.expectEqualStrings("example/archive", loaded.definition_id);
}
