const std = @import("std");
const canonical_json = @import("canonical_json.zig");
const definition_compat = @import("definition_compat");

const package_ancestor_count_max: usize = 256;

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

pub const AdmittedLocation = struct {
    root: []const u8,
    entry: []const u8,
};

pub fn admittedLocation(
    absolute_path: []const u8,
    current_root: []const u8,
    collection_basename: []const u8,
) !AdmittedLocation {
    if (!std.fs.path.isAbsolute(absolute_path) or
        !std.fs.path.isAbsolute(current_root))
    {
        return error.DefinitionRootNotAbsolute;
    }
    const root = canonicalPackageRoot(
        absolute_path,
        collection_basename,
    ) orelse
        if (pathWithin(absolute_path, current_root))
            current_root
        else
            std.fs.path.dirname(absolute_path) orelse
                return error.InvalidDefinitionPath;
    return .{
        .root = root,
        .entry = relativeWithin(absolute_path, root),
    };
}

pub fn admittedPackageLocation(
    absolute_path: []const u8,
    collection_basename: []const u8,
) !?AdmittedLocation {
    if (!std.fs.path.isAbsolute(absolute_path)) {
        return error.DefinitionRootNotAbsolute;
    }
    const root = canonicalPackageRoot(
        absolute_path,
        collection_basename,
    ) orelse return null;
    return .{
        .root = root,
        .entry = relativeWithin(absolute_path, root),
    };
}

fn canonicalPackageRoot(
    absolute_path: []const u8,
    collection_basename: []const u8,
) ?[]const u8 {
    if (collection_basename.len == 0 or
        std.mem.indexOfScalar(u8, collection_basename, std.fs.path.sep) != null)
    {
        return null;
    }
    var cursor = std.fs.path.dirname(absolute_path) orelse return null;
    for (0..package_ancestor_count_max) |_| {
        if (std.mem.eql(u8, std.fs.path.basename(cursor), "definitions")) {
            if (!hasRegularPackageManifest(cursor)) return null;
            const package = std.fs.path.dirname(cursor) orelse return null;
            const collection = std.fs.path.dirname(package) orelse return null;
            if (!std.mem.eql(
                u8,
                std.fs.path.basename(collection),
                collection_basename,
            )) return null;
            if (std.mem.eql(
                u8,
                collection,
                std.fs.path.dirname(collection) orelse return null,
            )) return null;
            return collection;
        }
        const parent = std.fs.path.dirname(cursor) orelse return null;
        if (std.mem.eql(u8, parent, cursor)) return null;
        cursor = parent;
    }
    return null;
}

fn hasRegularPackageManifest(definitions_root: []const u8) bool {
    const manifest_path = std.fs.path.join(
        std.heap.page_allocator,
        &.{ definitions_root, "manifest.json" },
    ) catch return false;
    defer std.heap.page_allocator.free(manifest_path);
    const stat = std.Io.Dir.cwd().statFile(
        defaultIo(),
        manifest_path,
        .{ .follow_symlinks = false },
    ) catch return false;
    return stat.kind == .file;
}

fn pathWithin(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or
        (path.len > root.len and
            std.mem.startsWith(u8, path, root) and
            path[root.len] == std.fs.path.sep);
}

fn relativeWithin(path: []const u8, root: []const u8) []const u8 {
    if (std.mem.eql(u8, path, root)) return "";
    return path[root.len + 1 ..];
}

pub const ClosureFile = struct {
    path: []u8,
    canonical_json: []u8,
    source_digest: [32]u8 = [_]u8{0} ** 32,
    source_bytes: usize = 0,

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

/// The path borrows an admitted file; unvisited import paths belong to this frame.
const ImportFrame = struct {
    path: []const u8,
    imports: std.ArrayList([]u8),
    next_import: usize = 0,

    fn deinit(self: *ImportFrame, allocator: std.mem.Allocator) void {
        for (self.imports.items[self.next_import..]) |path| allocator.free(path);
        self.imports.deinit(allocator);
        self.* = undefined;
    }

    fn takeNext(self: *ImportFrame) ?[]u8 {
        if (self.next_import == self.imports.items.len) return null;
        const path = self.imports.items[self.next_import];
        self.next_import += 1;
        return path;
    }
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
        var frames: std.ArrayList(ImportFrame) = .empty;
        defer {
            for (frames.items) |*frame| frame.deinit(self.allocator);
            frames.deinit(self.allocator);
        }
        try self.enter(&frames, relative_path, depth);
        while (frames.items.len != 0) {
            const frame = &frames.items[frames.items.len - 1];
            if (frame.takeNext()) |path| {
                try self.enter(&frames, path, depth + frames.items.len);
            } else {
                self.states.getPtr(frame.path).?.* = .complete;
                var complete = frames.pop().?;
                complete.deinit(self.allocator);
            }
        }
    }

    fn enter(
        self: *Builder,
        frames: *std.ArrayList(ImportFrame),
        relative_path: []u8,
        depth: usize,
    ) !void {
        var path_owned = true;
        defer if (path_owned) self.allocator.free(relative_path);
        if (try self.visitComplete(relative_path, depth)) return;
        var loaded = try self.loadDefinition(relative_path);
        defer loaded.deinit(self.allocator);
        try self.states.put(self.allocator, relative_path, .visiting);
        errdefer _ = self.states.remove(relative_path);
        try self.files.append(self.allocator, .{
            .path = relative_path,
            .canonical_json = loaded.canonical_json,
            .source_digest = loaded.source_digest,
            .source_bytes = loaded.source_bytes,
        });
        path_owned = false;
        loaded.canonical_owned = false;
        self.total_definition_bytes = loaded.next_total;
        std.sort.heap([]u8, loaded.imports.items, {}, lessThanPath);
        // Each live frame owns a distinct admitted file, bounded by both limits.
        std.debug.assert(frames.items.len < self.limits.max_files);
        std.debug.assert(depth <= self.limits.max_import_depth);
        try frames.append(self.allocator, .{
            .path = relative_path,
            .imports = loaded.imports,
        });
        loaded.imports = .empty;
    }

    fn visitComplete(
        self: *Builder,
        relative_path: []const u8,
        depth: usize,
    ) !bool {
        if (depth > self.limits.max_import_depth) {
            return error.ImportDepthExceeded;
        }
        if (self.states.get(relative_path)) |state| {
            if (state == .visiting) return error.ImportCycle;
            return true;
        }
        if (self.files.items.len == self.limits.max_files) {
            return error.TooManyDefinitionFiles;
        }
        return false;
    }

    fn loadDefinition(
        self: *Builder,
        relative_path: []const u8,
    ) !LoadedDefinition {
        const raw = try readAdmittedFileAlloc(
            self.root,
            relative_path,
            self.allocator,
            self.limits.max_file_bytes,
        );
        defer self.allocator.free(raw);
        const source_bytes = raw.len;
        const next_total = std.math.add(
            usize,
            self.total_definition_bytes,
            source_bytes,
        ) catch return error.DefinitionClosureTooLarge;
        if (next_total > self.limits.max_total_bytes) {
            return error.DefinitionClosureTooLarge;
        }
        var parsed = try parseDefinition(self.allocator, raw);
        defer parsed.deinit();
        var loaded = LoadedDefinition{
            .canonical_json = try canonicalDefinitionAlloc(
                self.allocator,
                parsed.value,
            ),
            .source_digest = undefined,
            .source_bytes = raw.len,
            .next_total = next_total,
        };
        errdefer loaded.deinit(self.allocator);
        std.crypto.hash.sha2.Sha256.hash(raw, &loaded.source_digest, .{});
        try collectImports(
            self.allocator,
            parsed.value.object,
            std.fs.path.dirname(relative_path) orelse "",
            &loaded.imports,
        );
        return loaded;
    }
};

const LoadedDefinition = struct {
    canonical_json: []u8,
    source_digest: [32]u8,
    source_bytes: usize,
    next_total: usize,
    imports: std.ArrayList([]u8) = .empty,
    canonical_owned: bool = true,

    fn deinit(self: *LoadedDefinition, allocator: std.mem.Allocator) void {
        if (self.canonical_owned) allocator.free(self.canonical_json);
        for (self.imports.items) |item| allocator.free(item);
        self.imports.deinit(allocator);
        self.* = undefined;
    }
};

fn parseDefinition(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !std.json.Parsed(std.json.Value) {
    if (!std.unicode.utf8ValidateSlice(raw)) {
        return error.InvalidDefinitionUtf8;
    }
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        raw,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
        },
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.DuplicateField => return error.DuplicateDefinitionField,
        else => return error.InvalidDefinitionJson,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.DefinitionRootNotObject;
    return parsed;
}

fn canonicalDefinitionAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]u8 {
    return canonical_json.canonicalJsonAlloc(
        allocator,
        value,
    ) catch |err| switch (err) {
        error.InvalidNumber,
        error.NonFiniteNumber,
        error.InvalidUtf8,
        => return error.InvalidDefinitionJson,
        else => return err,
    };
}

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
    std.sort.heap(ClosureFile, builder.files.items, {}, lessThanClosureFile);
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
        try validateCanonicalSource(allocator, source, limits);
        total_definition_bytes = try addDefinitionBytes(
            total_definition_bytes,
            source.canonical_json.len,
            limits,
        );
        files[index] = try cloneCanonicalFile(allocator, source);
        initialized += 1;
    }
    std.sort.heap(ClosureFile, files, {}, lessThanClosureFile);
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

fn addDefinitionBytes(
    current: usize,
    added: usize,
    limits: Limits,
) !usize {
    if (added > limits.max_file_bytes) {
        return error.DefinitionFileTooLarge;
    }
    const total = std.math.add(
        usize,
        current,
        added,
    ) catch return error.DefinitionClosureTooLarge;
    if (total > limits.max_total_bytes) {
        return error.DefinitionClosureTooLarge;
    }
    return total;
}

fn validateCanonicalSource(
    allocator: std.mem.Allocator,
    source: ClosureFile,
    limits: Limits,
) !void {
    const normalized = try normalizeRelativeAlloc(allocator, "", source.path);
    defer allocator.free(normalized);
    if (!std.mem.eql(u8, normalized, source.path)) {
        return error.InvalidDefinitionPath;
    }
    if (source.canonical_json.len > limits.max_file_bytes) {
        return error.DefinitionFileTooLarge;
    }
}

fn cloneCanonicalFile(
    allocator: std.mem.Allocator,
    source: ClosureFile,
) !ClosureFile {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        source.canonical_json,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
        },
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidDefinitionJson,
    };
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
    const path = try allocator.dupe(u8, source.path);
    var source_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        source.canonical_json,
        &source_digest,
        .{},
    );
    return .{
        .path = path,
        .canonical_json = canonical,
        .source_digest = source_digest,
        .source_bytes = source.canonical_json.len,
    };
}

pub fn verifySourceManifest(
    allocator: std.mem.Allocator,
    admitted_root: []const u8,
    files: anytype,
    limits: Limits,
) !usize {
    try limits.validate();
    if (!std.fs.path.isAbsolute(admitted_root)) {
        return error.DefinitionRootNotAbsolute;
    }
    if (files.len == 0 or files.len > limits.max_files) {
        return error.TooManyDefinitionFiles;
    }
    try rejectAbsoluteSymlinkComponents(admitted_root);
    var root = try std.Io.Dir.openDirAbsolute(defaultIo(), admitted_root, .{
        .follow_symlinks = false,
    });
    defer root.close(defaultIo());

    var total_bytes: usize = 0;
    var prior_path: ?[]const u8 = null;
    for (files) |file| {
        try validateManifestPath(allocator, file.path);
        if (prior_path) |prior| {
            if (std.mem.order(u8, prior, file.path) != .lt) {
                return error.DefinitionManifestNotSorted;
            }
        }
        prior_path = file.path;
        total_bytes = try addDefinitionBytes(
            total_bytes,
            file.source_bytes,
            limits,
        );
        try verifySourceFile(allocator, &root, file, limits);
    }
    return total_bytes;
}

fn verifySourceFile(
    allocator: std.mem.Allocator,
    root: *std.Io.Dir,
    file: anytype,
    limits: Limits,
) !void {
    const raw = try readAdmittedFileAlloc(
        root,
        file.path,
        allocator,
        limits.max_file_bytes,
    );
    defer allocator.free(raw);
    if (raw.len != file.source_bytes) {
        return error.DefinitionSourceSizeMismatch;
    }
    if (!std.unicode.utf8ValidateSlice(raw)) {
        return error.InvalidDefinitionUtf8;
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    if (!std.mem.eql(u8, &digest, &file.source_digest)) {
        return error.DefinitionSourceDigestMismatch;
    }
}

fn readAdmittedFileAlloc(
    root: *std.Io.Dir,
    relative_path: []const u8,
    allocator: std.mem.Allocator,
    max_file_bytes: usize,
) ![]u8 {
    try rejectSymlinkComponents(root, relative_path);
    var source = root.openFile(defaultIo(), relative_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.IsDir => return error.DefinitionNotRegularFile,
        else => return err,
    };
    defer source.close(defaultIo());
    const stat = try source.stat(defaultIo());
    if (stat.kind == .sym_link) return error.SymlinkDefinitionPath;
    if (stat.kind != .file) return error.DefinitionNotRegularFile;
    if (stat.size > max_file_bytes) return error.DefinitionFileTooLarge;
    const read_limit = std.math.add(
        usize,
        max_file_bytes,
        1,
    ) catch return error.DefinitionFileTooLarge;
    var reader = source.reader(defaultIo(), &.{});
    const raw = reader.interface.allocRemaining(
        allocator,
        .limited(read_limit),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.DefinitionFileTooLarge,
        else => return err,
    };
    errdefer allocator.free(raw);
    if (raw.len > max_file_bytes) return error.DefinitionFileTooLarge;
    return raw;
}

fn validateManifestPath(
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    const normalized = try normalizeRelativeAlloc(allocator, "", path);
    defer allocator.free(normalized);
    if (!std.mem.eql(u8, normalized, path)) {
        return error.InvalidDefinitionPath;
    }
}

pub fn validateCached(
    allocator: std.mem.Allocator,
    cached: *const Closure,
    entry_path: []const u8,
    limits: Limits,
) !void {
    try limits.validate();
    if (cached.files.len == 0 or cached.files.len > limits.max_files) {
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

    var total_source_bytes: usize = 0;
    var total_canonical_bytes: usize = 0;
    for (cached.files, 0..) |file, index| {
        try validateCachedFile(allocator, cached, file, index, limits);
        total_source_bytes = try addDefinitionBytes(
            total_source_bytes,
            file.source_bytes,
            limits,
        );
        total_canonical_bytes = try addDefinitionBytes(
            total_canonical_bytes,
            file.canonical_json.len,
            limits,
        );
    }
    if (cached.find(entry_path) == null) return error.EntryDefinitionMissing;
    if (cached.total_definition_bytes != total_source_bytes) {
        return error.DefinitionSourceSizeMismatch;
    }
    const digest = digestFiles(cached.files);
    if (!std.mem.eql(u8, &digest, &cached.digest)) {
        return error.DefinitionClosureDigestMismatch;
    }
}

fn validateCachedFile(
    allocator: std.mem.Allocator,
    cached: *const Closure,
    file: ClosureFile,
    index: usize,
    limits: Limits,
) !void {
    const normalized = try normalizeRelativeAlloc(
        allocator,
        "",
        file.path,
    );
    defer allocator.free(normalized);
    if (!std.mem.eql(u8, normalized, file.path)) {
        return error.InvalidDefinitionPath;
    }
    if (index != 0 and
        std.mem.order(
            u8,
            cached.files[index - 1].path,
            file.path,
        ) != .lt)
    {
        return error.DefinitionManifestNotSorted;
    }
    if (file.source_bytes > limits.max_file_bytes or
        file.canonical_json.len > limits.max_file_bytes)
    {
        return error.DefinitionFileTooLarge;
    }
    if (!std.unicode.utf8ValidateSlice(file.canonical_json)) {
        return error.InvalidDefinitionUtf8;
    }
}

const CanonicalClosureValidator = struct {
    allocator: std.mem.Allocator,
    files: []const ClosureFile,
    limits: Limits,
    states: std.StringHashMapUnmanaged(VisitState) = .empty,
    complete_count: usize = 0,

    fn visit(self: *CanonicalClosureValidator, path: []const u8, depth: usize) !void {
        var frames: std.ArrayList(ImportFrame) = .empty;
        defer {
            for (frames.items) |*frame| frame.deinit(self.allocator);
            frames.deinit(self.allocator);
        }
        try self.enter(&frames, try self.allocator.dupe(u8, path), depth);
        while (frames.items.len != 0) {
            const frame = &frames.items[frames.items.len - 1];
            if (frame.takeNext()) |import_path| {
                try self.enter(&frames, import_path, depth + frames.items.len);
            } else {
                self.states.getPtr(frame.path).?.* = .complete;
                self.complete_count += 1;
                var complete = frames.pop().?;
                complete.deinit(self.allocator);
            }
        }
    }

    fn enter(
        self: *CanonicalClosureValidator,
        frames: *std.ArrayList(ImportFrame),
        path: []u8,
        depth: usize,
    ) !void {
        defer self.allocator.free(path);
        if (depth > self.limits.max_import_depth) return error.ImportDepthExceeded;
        if (self.states.get(path)) |state| {
            if (state == .visiting) return error.ImportCycle;
            return;
        }
        const file = findFile(self.files, path) orelse return error.ImportedDefinitionMissing;
        try self.states.put(self.allocator, file.path, .visiting);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            file.canonical_json,
            .{ .duplicate_field_behavior = .@"error" },
        );
        defer parsed.deinit();
        var imports: std.ArrayList([]u8) = .empty;
        errdefer {
            for (imports.items) |item| self.allocator.free(item);
            imports.deinit(self.allocator);
        }
        try collectImports(
            self.allocator,
            parsed.value.object,
            std.fs.path.dirname(file.path) orelse "",
            &imports,
        );
        std.sort.heap([]u8, imports.items, {}, lessThanPath);
        std.debug.assert(frames.items.len < self.files.len);
        std.debug.assert(depth <= self.limits.max_import_depth);
        try frames.append(self.allocator, .{ .path = file.path, .imports = imports });
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

pub fn normalizeRelativeAlloc(
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
    hasher.update(definition_compat.closure_digest_frame);
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

test "canonical definition archives preserve exact JSON numbers" {
    const source = ClosureFile{
        .path = @constCast("definition.json"),
        .canonical_json = @constCast(
            "{\"value\":9223372036854775808}",
        ),
        .source_digest = undefined,
    };
    var cloned = try cloneCanonicalFile(std.testing.allocator, source);
    defer cloned.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        source.canonical_json,
        cloned.canonical_json,
    );
}

test "unrecognized definition folders do not widen the admitted root" {
    const external = try admittedLocation(
        "/opt/config/packages/first/definitions/artifacts/record.json",
        "/workspace/target",
        "skills",
    );
    try std.testing.expectEqualStrings(
        "/opt/config/packages/first/definitions/artifacts",
        external.root,
    );
    try std.testing.expectEqualStrings(
        "record.json",
        external.entry,
    );
    try std.testing.expect((try admittedPackageLocation(
        "/opt/config/packages/first/definitions/artifacts/record.json",
        "skills",
    )) == null);
    const containing_cwd = try admittedLocation(
        "/opt/config/packages/first/definitions/artifacts/record.json",
        "/opt/config",
        "skills",
    );
    try std.testing.expectEqualStrings("/opt/config", containing_cwd.root);
    try std.testing.expectEqualStrings(
        "packages/first/definitions/artifacts/record.json",
        containing_cwd.entry,
    );
    const root_safe = try admittedLocation(
        "/tmp/definitions/standalone.json",
        "/workspace/target",
        "skills",
    );
    try std.testing.expectEqualStrings(
        "/tmp/definitions",
        root_safe.root,
    );
    try std.testing.expectEqualStrings("standalone.json", root_safe.entry);
    const standalone = try admittedLocation(
        "/tmp/standalone.json",
        "/workspace/target",
        "skills",
    );
    try std.testing.expectEqualStrings("/tmp", standalone.root);
    try std.testing.expectEqualStrings("standalone.json", standalone.entry);
}

test "manifested definition packages admit cross-package imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(
        std.testing.io,
        "packages/first/definitions/artifacts",
    );
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packages/first/definitions/manifest.json",
        .data = "{}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packages/first/definitions/artifacts/record.json",
        .data = "{}",
    });
    const absolute = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "packages/first/definitions/artifacts/record.json",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(absolute);
    const location = (try admittedPackageLocation(
        absolute,
        "packages",
    )).?;
    const packages_root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "packages",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(packages_root);
    try std.testing.expectEqualStrings(packages_root, location.root);
    try std.testing.expectEqualStrings(
        "first/definitions/artifacts/record.json",
        location.entry,
    );
}

test "closure resolves explicit imports across admitted packages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(
        std.testing.io,
        "first/definitions/artifacts",
    );
    try tmp.dir.createDirPath(
        std.testing.io,
        "second/definitions/artifacts",
    );
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "first/definitions/artifacts/root.json",
        .data =
        \\{
        \\  "imports": [
        \\    {
        \\      "id": "second/child",
        \\      "path": "../../../second/definitions/artifacts/child.json"
        \\    }
        \\  ],
        \\  "schema": "example/v1"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "second/definitions/artifacts/child.json",
        .data =
        \\{"schema":"example-child/v1"}
        ,
    });
    var closure = try loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "first/definitions/artifacts/root.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), closure.files.len);
    try std.testing.expect(
        closure.find("second/definitions/artifacts/child.json") != null,
    );
}

test "closure is canonical, deterministically ordered, and content addressed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "nested", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "root.json",
        .data =
        \\{"schema":"example/v1","imports":[{"id":"b","path":"nested/b.json"},"a.json"],"z":9007199254740992.1,"a":2}
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
        "{\"a\":2,\"imports\":[{\"id\":\"b\"," ++
            "\"path\":\"nested/b.json\"},\"a.json\"]," ++
            "\"schema\":\"example/v1\",\"z\":9007199254740992.1}",
        closure.files[2].canonical_json,
    );
    try std.testing.expect(canonical_json.isFingerprint(closure.digestSlice()));

    var repeated = try loadFromDir(std.testing.allocator, &tmp.dir, "./root.json", .{});
    defer repeated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(closure.digestSlice(), repeated.digestSlice());
}

test "source manifest verifies unchanged files without reparsing definitions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "root.json",
        .data = "{\"schema\":\"example/v1\",\"imports\":[\"child.json\"]}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "child.json",
        .data = "{\"schema\":\"example-child/v1\",\"value\":1}",
    });
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    var closure = try load(
        std.testing.allocator,
        root,
        "root.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        closure.total_definition_bytes,
        try verifySourceManifest(
            std.testing.allocator,
            root,
            closure.files,
            .{},
        ),
    );

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "child.json",
        .data = "{\"schema\": \"example-child/v1\", \"value\": 1}",
    });
    try std.testing.expectError(
        error.DefinitionSourceSizeMismatch,
        verifySourceManifest(
            std.testing.allocator,
            root,
            closure.files,
            .{},
        ),
    );
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

fn chainFixture(allocator: std.mem.Allocator, count: usize) !Closure {
    std.debug.assert(count > 0 and count < 1000);
    const files = try allocator.alloc(ClosureFile, count);
    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |*file| file.deinit(allocator);
        allocator.free(files);
    }
    var total: usize = 0;
    for (files, 0..) |*file, index| {
        const path = try std.fmt.allocPrint(allocator, "f{d:0>3}.json", .{index});
        errdefer allocator.free(path);
        const bytes = if (index + 1 == count)
            try allocator.dupe(u8, "{}")
        else
            try std.fmt.allocPrint(
                allocator,
                "{{\"imports\":[\"f{d:0>3}.json\"]}}",
                .{index + 1},
            );
        file.* = .{
            .path = path,
            .canonical_json = bytes,
            .source_digest = undefined,
            .source_bytes = bytes.len,
        };
        std.crypto.hash.sha2.Sha256.hash(bytes, &file.source_digest, .{});
        total += bytes.len;
        initialized += 1;
    }
    return .{ .files = files, .digest = digestFiles(files), .total_definition_bytes = total };
}

test "iterative import traversal preserves deep source and canonical closure bytes" {
    var source = try chainFixture(std.testing.allocator, 96);
    defer source.deinit(std.testing.allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (source.files) |file| {
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = file.path,
            .data = file.canonical_json,
        });
    }
    const limits: Limits = .{ .max_import_depth = 96, .max_files = 96 };
    var loaded = try loadFromDir(std.testing.allocator, &tmp.dir, "f000.json", limits);
    defer loaded.deinit(std.testing.allocator);
    var canonical = try fromCanonicalFiles(
        std.testing.allocator,
        source.files,
        "f000.json",
        limits,
    );
    defer canonical.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(&source.digest, &loaded.digest);
    try std.testing.expectEqualStrings(&source.digest, &canonical.digest);
    const shallow: Limits = .{ .max_import_depth = 95 };
    try std.testing.expectError(
        error.ImportDepthExceeded,
        loadFromDir(std.testing.allocator, &tmp.dir, "f000.json", shallow),
    );
    try std.testing.expectError(
        error.ImportDepthExceeded,
        fromCanonicalFiles(std.testing.allocator, source.files, "f000.json", shallow),
    );
}

test "import depth precedes cycles and cycles precede new-file admission" {
    const bytes = "{\"imports\":[\"a.json\"]}";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.json", .data = bytes });
    const files = [_]ClosureFile{.{
        .path = @constCast("a.json"),
        .canonical_json = @constCast(bytes),
        .source_digest = [_]u8{0} ** 32,
        .source_bytes = bytes.len,
    }};
    const shallow: Limits = .{ .max_import_depth = 1, .max_files = 1 };
    try std.testing.expectError(
        error.ImportDepthExceeded,
        loadFromDir(std.testing.allocator, &tmp.dir, "a.json", shallow),
    );
    try std.testing.expectError(
        error.ImportDepthExceeded,
        fromCanonicalFiles(std.testing.allocator, &files, "a.json", shallow),
    );
    const deep: Limits = .{ .max_import_depth = 2, .max_files = 1 };
    try std.testing.expectError(
        error.ImportCycle,
        loadFromDir(std.testing.allocator, &tmp.dir, "a.json", deep),
    );
    try std.testing.expectError(
        error.ImportCycle,
        fromCanonicalFiles(std.testing.allocator, &files, "a.json", deep),
    );
}

fn loadChainForAllocationFailure(allocator: std.mem.Allocator, root: *std.Io.Dir) !void {
    var loaded = loadFromDir(allocator, root, "f000.json", .{}) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer loaded.deinit(allocator);
}

fn canonicalChainForAllocationFailure(
    allocator: std.mem.Allocator,
    files: []const ClosureFile,
) !void {
    var loaded = fromCanonicalFiles(allocator, files, "f000.json", .{}) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer loaded.deinit(allocator);
}

test "import frames free pending siblings at every failed allocation" {
    var source = try chainFixture(std.testing.allocator, 3);
    defer source.deinit(std.testing.allocator);
    const root = &source.files[0];
    const branched = try std.testing.allocator.dupe(
        u8,
        "{\"imports\":[\"f001.json\",\"f002.json\"]}",
    );
    source.total_definition_bytes += branched.len - root.source_bytes;
    std.testing.allocator.free(root.canonical_json);
    root.canonical_json = branched;
    root.source_bytes = branched.len;
    std.crypto.hash.sha2.Sha256.hash(branched, &root.source_digest, .{});
    source.digest = digestFiles(source.files);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (source.files) |file| {
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = file.path,
            .data = file.canonical_json,
        });
    }
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        loadChainForAllocationFailure,
        .{&tmp.dir},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        canonicalChainForAllocationFailure,
        .{source.files},
    );
}
