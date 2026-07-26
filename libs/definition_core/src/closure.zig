const std = @import("std");
const canonical_json = @import("canonical_json.zig");

pub const Limits = struct {
    max_files: usize = 128,
    max_total_bytes: usize = 4 * 1024 * 1024,
    max_file_bytes: usize = 4 * 1024 * 1024,
    max_import_depth: usize = 32,

    pub fn validate(self: Limits) !void {
        if (self.max_files == 0 or self.max_total_bytes == 0 or
            self.max_file_bytes == 0 or self.max_import_depth == 0)
        {
            return error.InvalidClosureLimits;
        }
        if (self.max_file_bytes > self.max_total_bytes) {
            return error.InvalidClosureLimits;
        }
    }
};

pub const ClosureFile = struct {
    path: []u8,
    canonical_json: []u8,

    fn deinit(self: *ClosureFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.canonical_json);
        self.* = undefined;
    }
};

pub const Closure = struct {
    files: []ClosureFile,
    digest: [71]u8,
    total_definition_bytes: usize,

    pub fn deinit(self: *Closure, allocator: std.mem.Allocator) void {
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }

    pub fn digestSlice(self: *const Closure) []const u8 {
        return self.digest[0..];
    }

    pub fn find(self: *const Closure, path: []const u8) ?*const ClosureFile {
        var low: usize = 0;
        var high: usize = self.files.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, self.files[mid].path, path)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return &self.files[mid],
            }
        }
        return null;
    }
};

const VisitState = enum {
    visiting,
    complete,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    root: *std.Io.Dir,
    limits: Limits,
    files: std.ArrayList(ClosureFile) = .empty,
    states: std.StringHashMapUnmanaged(VisitState) = .empty,
    total_definition_bytes: usize = 0,

    fn deinit(self: *Builder) void {
        for (self.files.items) |*file| file.deinit(self.allocator);
        self.files.deinit(self.allocator);
        self.states.deinit(self.allocator);
        self.* = undefined;
    }

    fn visit(self: *Builder, relative_path: []u8, depth: usize) !void {
        var path_owned = true;
        errdefer if (path_owned) self.allocator.free(relative_path);
        if (depth > self.limits.max_import_depth) return error.ImportDepthExceeded;
        if (self.states.get(relative_path)) |state| {
            if (state == .visiting) return error.ImportCycle;
            self.allocator.free(relative_path);
            path_owned = false;
            return;
        }
        if (self.files.items.len == self.limits.max_files) {
            return error.TooManyDefinitionFiles;
        }

        try rejectSymlinkComponents(self.root, relative_path);
        const stat = try self.root.statFile(defaultIo(), relative_path, .{
            .follow_symlinks = false,
        });
        if (stat.kind == .sym_link) return error.SymlinkDefinitionPath;
        if (stat.kind != .file) return error.DefinitionNotRegularFile;
        if (stat.size > self.limits.max_file_bytes) return error.DefinitionFileTooLarge;
        const file_bytes: usize = std.math.cast(usize, stat.size) orelse
            return error.DefinitionFileTooLarge;
        const next_total = std.math.add(usize, self.total_definition_bytes, file_bytes) catch
            return error.DefinitionClosureTooLarge;
        if (next_total > self.limits.max_total_bytes) return error.DefinitionClosureTooLarge;

        const raw = try self.root.readFileAlloc(
            defaultIo(),
            relative_path,
            self.allocator,
            .limited(self.limits.max_file_bytes),
        );
        defer self.allocator.free(raw);
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidDefinitionUtf8;

        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            raw,
            .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
            },
        ) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateDefinitionField,
            else => return error.InvalidDefinitionJson,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.DefinitionRootNotObject;

        const canonical = canonical_json.canonicalJsonAlloc(
            self.allocator,
            parsed.value,
        ) catch |err| switch (err) {
            error.NumberOutOfRange,
            error.NonFiniteNumber,
            error.InvalidUtf8,
            => return error.InvalidDefinitionJson,
            else => return err,
        };
        var canonical_owned = true;
        errdefer if (canonical_owned) self.allocator.free(canonical);

        try self.states.put(self.allocator, relative_path, .visiting);
        errdefer _ = self.states.remove(relative_path);
        try self.files.append(self.allocator, .{
            .path = relative_path,
            .canonical_json = canonical,
        });
        path_owned = false;
        canonical_owned = false;
        self.total_definition_bytes = next_total;

        var imports: std.ArrayList([]u8) = .empty;
        defer {
            for (imports.items) |item| self.allocator.free(item);
            imports.deinit(self.allocator);
        }
        try collectImports(
            self.allocator,
            parsed.value.object,
            std.fs.path.dirname(relative_path) orelse "",
            &imports,
        );
        std.mem.sort([]u8, imports.items, {}, lessThanPath);
        for (imports.items) |*import_path| {
            const owned = import_path.*;
            import_path.* = try self.allocator.dupe(u8, "");
            try self.visit(owned, depth + 1);
        }
        self.states.getPtr(relative_path).?.* = .complete;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    admitted_root: []const u8,
    entry_path: []const u8,
    limits: Limits,
) !Closure {
    try limits.validate();
    if (!std.fs.path.isAbsolute(admitted_root)) return error.DefinitionRootNotAbsolute;
    try rejectAbsoluteSymlinkComponents(admitted_root);
    var root = try std.Io.Dir.openDirAbsolute(defaultIo(), admitted_root, .{
        .follow_symlinks = false,
    });
    defer root.close(defaultIo());
    return loadFromDir(allocator, &root, entry_path, limits);
}

pub fn loadFromDir(
    allocator: std.mem.Allocator,
    root: *std.Io.Dir,
    entry_path: []const u8,
    limits: Limits,
) !Closure {
    try limits.validate();
    const normalized_entry = try normalizeRelativeAlloc(allocator, "", entry_path);
    var builder = Builder{
        .allocator = allocator,
        .root = root,
        .limits = limits,
    };
    errdefer builder.deinit();
    try builder.visit(normalized_entry, 1);
    std.mem.sort(ClosureFile, builder.files.items, {}, lessThanClosureFile);
    const digest = digestFiles(builder.files.items);
    const files = try builder.files.toOwnedSlice(allocator);
    builder.states.deinit(allocator);
    return .{
        .files = files,
        .digest = digest,
        .total_definition_bytes = builder.total_definition_bytes,
    };
}

pub fn fromCanonicalFiles(
    allocator: std.mem.Allocator,
    source_files: []const ClosureFile,
    entry_path: []const u8,
    limits: Limits,
) !Closure {
    try limits.validate();
    if (source_files.len == 0 or source_files.len > limits.max_files) {
        return error.TooManyDefinitionFiles;
    }
    const normalized_entry = try normalizeRelativeAlloc(
        allocator,
        "",
        entry_path,
    );
    defer allocator.free(normalized_entry);
    if (!std.mem.eql(u8, normalized_entry, entry_path)) {
        return error.InvalidDefinitionPath;
    }
    const files = try allocator.alloc(ClosureFile, source_files.len);
    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |*file| file.deinit(allocator);
        allocator.free(files);
    }
    var total_definition_bytes: usize = 0;
    for (source_files, 0..) |source, index| {
        const normalized = try normalizeRelativeAlloc(allocator, "", source.path);
        defer allocator.free(normalized);
        if (!std.mem.eql(u8, normalized, source.path)) {
            return error.InvalidDefinitionPath;
        }
        if (source.canonical_json.len > limits.max_file_bytes) {
            return error.DefinitionFileTooLarge;
        }
        total_definition_bytes = std.math.add(
            usize,
            total_definition_bytes,
            source.canonical_json.len,
        ) catch return error.DefinitionClosureTooLarge;
        if (total_definition_bytes > limits.max_total_bytes) {
            return error.DefinitionClosureTooLarge;
        }
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            source.canonical_json,
            .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
            },
        ) catch return error.InvalidDefinitionJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.DefinitionRootNotObject;
        const canonical = try canonical_json.canonicalJsonAlloc(
            allocator,
            parsed.value,
        );
        errdefer allocator.free(canonical);
        if (!std.mem.eql(u8, canonical, source.canonical_json)) {
            return error.NonCanonicalDefinitionArchive;
        }
        files[index] = .{
            .path = try allocator.dupe(u8, source.path),
            .canonical_json = canonical,
        };
        initialized += 1;
    }
    std.mem.sort(ClosureFile, files, {}, lessThanClosureFile);
    for (files[1..], 1..) |file, index| {
        if (std.mem.eql(u8, files[index - 1].path, file.path)) {
            return error.DuplicateDefinitionPath;
        }
    }
    var validator = CanonicalClosureValidator{
        .allocator = allocator,
        .files = files,
        .limits = limits,
    };
    defer validator.states.deinit(allocator);
    try validator.visit(entry_path, 1);
    if (validator.complete_count != files.len) {
        return error.UnreachableDefinitionFile;
    }
    return .{
        .files = files,
        .digest = digestFiles(files),
        .total_definition_bytes = total_definition_bytes,
    };
}

const CanonicalClosureValidator = struct {
    allocator: std.mem.Allocator,
    files: []const ClosureFile,
    limits: Limits,
    states: std.StringHashMapUnmanaged(VisitState) = .empty,
    complete_count: usize = 0,

    fn visit(
        self: *CanonicalClosureValidator,
        path: []const u8,
        depth: usize,
    ) !void {
        if (depth > self.limits.max_import_depth) {
            return error.ImportDepthExceeded;
        }
        if (self.states.get(path)) |state| {
            if (state == .visiting) return error.ImportCycle;
            return;
        }
        const file = findFile(self.files, path) orelse
            return error.ImportedDefinitionMissing;
        try self.states.put(self.allocator, file.path, .visiting);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            file.canonical_json,
            .{ .duplicate_field_behavior = .@"error" },
        );
        defer parsed.deinit();
        var imports: std.ArrayList([]u8) = .empty;
        defer {
            for (imports.items) |item| self.allocator.free(item);
            imports.deinit(self.allocator);
        }
        try collectImports(
            self.allocator,
            parsed.value.object,
            std.fs.path.dirname(file.path) orelse "",
            &imports,
        );
        std.mem.sort([]u8, imports.items, {}, lessThanPath);
        for (imports.items) |import_path| {
            try self.visit(import_path, depth + 1);
        }
        self.states.getPtr(file.path).?.* = .complete;
        self.complete_count += 1;
    }
};

fn findFile(files: []const ClosureFile, path: []const u8) ?*const ClosureFile {
    var low: usize = 0;
    var high = files.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, files[mid].path, path)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return &files[mid],
        }
    }
    return null;
}

fn collectImports(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    base_dir: []const u8,
    out: *std.ArrayList([]u8),
) !void {
    const value = object.get("imports") orelse return;
    const items = switch (value) {
        .array => |array| array,
        else => return error.InvalidImports,
    };
    for (items.items) |item| {
        const raw_path = switch (item) {
            .string => |path| path,
            .object => |import_object| blk: {
                var iterator = import_object.iterator();
                while (iterator.next()) |entry| {
                    if (!std.mem.eql(u8, entry.key_ptr.*, "id") and
                        !std.mem.eql(u8, entry.key_ptr.*, "path"))
                    {
                        return error.InvalidImportObject;
                    }
                }
                const path_value = import_object.get("path") orelse
                    return error.InvalidImportObject;
                break :blk switch (path_value) {
                    .string => |path| path,
                    else => return error.InvalidImportObject,
                };
            },
            else => return error.InvalidImports,
        };
        const normalized = try normalizeRelativeAlloc(allocator, base_dir, raw_path);
        errdefer allocator.free(normalized);
        for (out.items) |prior| {
            if (std.mem.eql(u8, prior, normalized)) return error.DuplicateImport;
        }
        try out.append(allocator, normalized);
    }
}

fn normalizeRelativeAlloc(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    raw_path: []const u8,
) ![]u8 {
    if (raw_path.len == 0 or std.fs.path.isAbsolute(raw_path)) {
        return error.InvalidDefinitionPath;
    }
    if (std.mem.indexOfScalar(u8, raw_path, 0) != null or
        std.mem.indexOfScalar(u8, raw_path, '\\') != null)
    {
        return error.InvalidDefinitionPath;
    }
    for (raw_path) |byte| if (byte < 0x20 or byte == 0x7f) {
        return error.InvalidDefinitionPath;
    };

    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(allocator);
    try appendNormalizedComponents(allocator, &components, base_dir);
    try appendNormalizedComponents(allocator, &components, raw_path);
    if (components.items.len == 0) return error.InvalidDefinitionPath;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (components.items, 0..) |component, index| {
        if (index != 0) try out.writer.writeByte('/');
        try out.writer.writeAll(component);
    }
    const normalized = try out.toOwnedSlice();
    if (!std.mem.endsWith(u8, normalized, ".json")) {
        allocator.free(normalized);
        return error.DefinitionPathNotJson;
    }
    return normalized;
}

fn appendNormalizedComponents(
    allocator: std.mem.Allocator,
    components: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (components.items.len == 0) return error.DefinitionPathEscapesRoot;
            _ = components.pop();
            continue;
        }
        try components.append(allocator, component);
    }
}

fn rejectSymlinkComponents(root: *std.Io.Dir, relative_path: []const u8) !void {
    var iterator = std.fs.path.componentIterator(relative_path);
    while (iterator.next()) |component| {
        const stat = try root.statFile(defaultIo(), component.path, .{
            .follow_symlinks = false,
        });
        if (stat.kind == .sym_link) return error.SymlinkDefinitionPath;
    }
}

fn rejectAbsoluteSymlinkComponents(path: []const u8) !void {
    var iterator = std.fs.path.componentIterator(path);
    while (iterator.next()) |component| {
        const stat = try std.Io.Dir.cwd().statFile(defaultIo(), component.path, .{
            .follow_symlinks = false,
        });
        if (stat.kind == .sym_link) return error.SymlinkDefinitionPath;
    }
}

pub fn digestFiles(files: []const ClosureFile) [71]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("skill-definition-closure/v1\x00");
    var length_bytes: [8]u8 = undefined;
    for (files) |file| {
        std.mem.writeInt(u64, &length_bytes, @intCast(file.path.len), .big);
        hasher.update(&length_bytes);
        hasher.update(file.path);
        std.mem.writeInt(u64, &length_bytes, @intCast(file.canonical_json.len), .big);
        hasher.update(&length_bytes);
        hasher.update(file.canonical_json);
    }
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    var digest: [71]u8 = undefined;
    @memcpy(digest[0..7], "sha256:");
    @memcpy(digest[7..], &hex);
    return digest;
}

fn lessThanPath(_: void, left: []u8, right: []u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn lessThanClosureFile(_: void, left: ClosureFile, right: ClosureFile) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "closure is canonical, deterministically ordered, and content addressed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "nested", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "root.json",
        .data =
        \\{"schema":"example/v1","imports":[{"id":"b","path":"nested/b.json"},"a.json"],"z":1,"a":2}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "a.json",
        .data = "{\"schema\":\"example-import/v1\",\"value\":1}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "nested/b.json",
        .data = "{\"value\":2,\"schema\":\"example-import/v1\"}",
    });

    var closure = try loadFromDir(std.testing.allocator, &tmp.dir, "root.json", .{});
    defer closure.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), closure.files.len);
    try std.testing.expectEqualStrings("a.json", closure.files[0].path);
    try std.testing.expectEqualStrings("nested/b.json", closure.files[1].path);
    try std.testing.expectEqualStrings("root.json", closure.files[2].path);
    try std.testing.expectEqualStrings(
        "{\"a\":2,\"imports\":[{\"id\":\"b\",\"path\":\"nested/b.json\"},\"a.json\"],\"schema\":\"example/v1\",\"z\":1}",
        closure.files[2].canonical_json,
    );
    try std.testing.expect(canonical_json.isFingerprint(closure.digestSlice()));

    var repeated = try loadFromDir(std.testing.allocator, &tmp.dir, "./root.json", .{});
    defer repeated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(closure.digestSlice(), repeated.digestSlice());
}

test "closure rejects cycles, root escapes, duplicate fields, and bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "a.json",
        .data = "{\"schema\":\"example/v1\",\"imports\":[\"b.json\"]}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "b.json",
        .data = "{\"schema\":\"example/v1\",\"imports\":[\"a.json\"]}",
    });
    try std.testing.expectError(
        error.ImportCycle,
        loadFromDir(std.testing.allocator, &tmp.dir, "a.json", .{}),
    );
    try std.testing.expectError(
        error.DefinitionPathEscapesRoot,
        loadFromDir(std.testing.allocator, &tmp.dir, "../a.json", .{}),
    );

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "duplicate.json",
        .data = "{\"schema\":\"one\",\"schema\":\"two\"}",
    });
    try std.testing.expectError(
        error.DuplicateDefinitionField,
        loadFromDir(std.testing.allocator, &tmp.dir, "duplicate.json", .{}),
    );
    try std.testing.expectError(
        error.DefinitionFileTooLarge,
        loadFromDir(std.testing.allocator, &tmp.dir, "a.json", .{
            .max_file_bytes = 1,
            .max_total_bytes = 1,
        }),
    );
}

test "closure rejects symlink traversal and non-regular files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "real.json",
        .data = "{\"schema\":\"example/v1\"}",
    });
    try tmp.dir.symLink(std.testing.io, "real.json", "link.json", .{});
    try std.testing.expectError(
        error.SymlinkDefinitionPath,
        loadFromDir(std.testing.allocator, &tmp.dir, "link.json", .{}),
    );
    try tmp.dir.createDir(std.testing.io, "directory.json", .default_dir);
    try std.testing.expectError(
        error.DefinitionNotRegularFile,
        loadFromDir(std.testing.allocator, &tmp.dir, "directory.json", .{}),
    );
}
