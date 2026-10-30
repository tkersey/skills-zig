const std = @import("std");
const definition_core = @import("definition_core");
const storage_sources = @import("storage_sources.zig");
const storage_source_admission = @import("storage_source_admission.zig");
const storage_preparation = @import("storage_preparation.zig");
const definition_archive = @import("definition_archive.zig");
const definition = @import("definition.zig");
const durable_store = @import("durable_store");
const storage_root = @import("storage_root");
const json = definition_core.json;

pub const schema = "ledger-preservation-bundle/v1";
pub const Scope = enum { declared, historical };
pub const max_files: usize = 10_000;

pub const Limits = struct {
    files: usize = max_files,
    sources: usize = storage_sources.max_sources,
    observations: usize = storage_sources.max_observations,
    manifest_bytes: usize = storage_sources.max_manifest_bytes,
    payload_bytes: u64,

    fn validate(self: Limits) !void {
        if (self.files > max_files or self.sources > storage_sources.max_sources or
            self.observations > storage_sources.max_observations or
            self.manifest_bytes > storage_sources.max_manifest_bytes)
        {
            return error.InvalidBundleLimits;
        }
    }
};

pub const File = struct {
    path: []const u8,
    content_id: []const u8,
    byte_length: u64,
    definition_closure: ?[]const u8 = null,
};

pub const Target = struct { store_id: []const u8, generation: []const u8 };

pub const EvidenceSubject = struct {
    observation_id: []const u8,
    subject: storage_sources.Subject,
};

pub const SourceWitness = struct {
    subject: storage_sources.Subject,
    files: []const File,
};

pub const MergeView = struct {
    description: Description,
    files: []const CapturedFile,
};

pub const SourceSelection = struct { input: usize, source: usize };

pub fn assembleSources(
    allocator: std.mem.Allocator,
    inputs: []const MergeView,
    selected: SourceSelection,
    target: Target,
    limits: Limits,
) !Captured {
    try limits.validate();
    if (inputs.len == 0 or inputs.len > limits.sources) return error.TooManySources;
    if (selected.input >= inputs.len or
        selected.source >= inputs[selected.input].description.sources.len)
    {
        return error.InvalidPreparationTarget;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var assembly: SourceAssembly = .{
        .allocator = arena.allocator(),
        .scratch_allocator = allocator,
        .limits = limits,
        .by_path = .init(arena.allocator()),
    };
    for (inputs) |input| try assembly.include(input);
    try assembly.select(inputs[selected.input].description.sources[selected.source]);
    var description = inputs[selected.input].description;
    description.target = target;
    description.observations = assembly.observations.items;
    description.evidence_subjects = assembly.subjects.items;
    description.sources = assembly.sources.items;
    return assembly.finish(&arena, description);
}

const SourceAssembly = struct {
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    limits: Limits,
    files: std.ArrayList(CapturedFile) = .empty,
    by_path: std.StringHashMap(usize),
    payload_bytes: u64 = 0,
    raw: std.StringHashMapUnmanaged([]const u8) = .empty,
    observations: std.ArrayList(storage_sources.Observation) = .empty,
    subjects: std.ArrayList(EvidenceSubject) = .empty,
    sources: std.ArrayList(SourceWitness) = .empty,
    source_references: usize = 0,

    fn include(self: *SourceAssembly, input: MergeView) !void {
        for (input.files) |file| {
            const descriptor = try validateCapturedFile(
                self.scratch_allocator,
                input.description.files,
                file,
            );
            const entry = try self.raw.getOrPut(self.allocator, descriptor.content_id);
            if (entry.found_existing) {
                if (!std.mem.eql(u8, entry.value_ptr.*, file.content)) {
                    return error.ConflictingBundleContent;
                }
            } else {
                if (self.raw.count() > self.limits.files) return error.TooManyBundleFiles;
                entry.value_ptr.* = file.content;
            }
        }
        for (input.description.sources) |source| try self.includeSource(source);
        for (input.description.observations) |observation| try self.includeObservation(observation);
        for (input.description.evidence_subjects) |subject| try self.includeSubject(subject);
    }

    fn includeSource(self: *SourceAssembly, source: SourceWitness) !void {
        var low: usize = 0;
        var high = self.sources.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (compareSources(self.sources.items[middle], source)) {
                .eq => return,
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        if (self.sources.items.len == self.limits.sources) return error.TooManySources;
        if (source.files.len > self.limits.files - self.source_references) {
            return error.TooManyBundleFiles;
        }
        try self.sources.insert(self.allocator, low, source);
        self.source_references += source.files.len;
    }

    fn includeObservation(self: *SourceAssembly, observation: storage_sources.Observation) !void {
        var low: usize = 0;
        var high = self.observations.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const prior = self.observations.items[middle];
            switch (std.mem.order(u8, prior.observation_id, observation.observation_id)) {
                .eq => {
                    var pair = [_]storage_sources.Observation{ prior, observation };
                    _ = try coalesceObservations(&pair);
                    return;
                },
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        if (self.observations.items.len == self.limits.observations) {
            return error.TooManyObservations;
        }
        try self.observations.insert(self.allocator, low, observation);
    }

    fn includeSubject(self: *SourceAssembly, subject: EvidenceSubject) !void {
        var low: usize = 0;
        var high = self.subjects.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const prior = self.subjects.items[middle];
            if (evidenceSubjectLessThan({}, prior, subject)) {
                low = middle + 1;
            } else if (evidenceSubjectLessThan({}, subject, prior)) {
                high = middle;
            } else {
                if (!sameSubject(prior.subject, subject.subject)) {
                    return error.ConflictingObservationSubject;
                }
                return;
            }
        }
        if (self.subjects.items.len == self.limits.observations) {
            return error.TooManyObservations;
        }
        try self.subjects.insert(self.allocator, low, subject);
    }

    fn select(self: *SourceAssembly, source: SourceWitness) !void {
        var installed = std.StringHashMap(void).init(self.scratch_allocator);
        defer installed.deinit();
        for (source.files) |descriptor| {
            const bytes = self.raw.get(descriptor.content_id) orelse
                return error.BundleSourceFileMissing;
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
            try appendCapturedFile(
                self,
                descriptor.path,
                bytes,
                descriptor.definition_closure,
                hash,
            );
            try installed.put(descriptor.content_id, {});
        }
        var iterator = self.raw.iterator();
        while (iterator.next()) |entry| {
            if (installed.contains(entry.key_ptr.*)) continue;
            try appendEvidence(self, entry.value_ptr.*);
        }
    }

    fn finish(
        self: *SourceAssembly,
        arena: *std.heap.ArenaAllocator,
        supplied: Description,
    ) !Captured {
        var description = supplied;
        const descriptors = try self.allocator.alloc(File, self.files.items.len);
        for (self.files.items, descriptors) |file, *descriptor| descriptor.* = file.descriptor;
        description.files = descriptors;
        const bytes = try encode(self.allocator, description, self.limits);
        var manifest = try parse(self.scratch_allocator, bytes, self.limits);
        defer manifest.deinit();
        const identity = try self.allocator.dupe(u8, manifest.digest);
        const files = try self.files.toOwnedSlice(self.allocator);
        return .{
            .arena = arena.*,
            .manifest = bytes,
            .identity = identity,
            .files = files,
            .payload_bytes = manifest.payload_bytes,
        };
    }
};

pub const Description = struct {
    schema: []const u8 = schema,
    scope: Scope,
    definition_id: []const u8,
    definition_digest: []const u8,
    definition_entry_path: []const u8,
    parameter_digest: []const u8,
    target: Target,
    observations: []const storage_sources.Observation,
    evidence_subjects: []const EvidenceSubject,
    sources: []const SourceWitness,
    files: []const File,
};

pub const Manifest = struct {
    parsed: std.json.Parsed(std.json.Value),
    description: Description,
    digest: []const u8,
    payload_bytes: u64,

    pub fn deinit(self: *Manifest) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !Manifest {
    try limits.validate();
    if (bytes.len > limits.manifest_bytes) return error.BundleManifestTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
    errdefer parsed.deinit();
    const arena = parsed.arena.allocator();
    const root = try json.object(parsed.value);
    const keys = &.{
        "schema",           "scope",  "definition_id", "definition_digest", "definition_entry_path",
        "parameter_digest", "target", "observations",  "files",             "evidence_subjects",
        "sources",
    };
    try json.requireExactKeys(root, keys);
    try json.requireFields(root, keys);
    if (!std.mem.eql(u8, try json.requiredString(root, "schema"), schema)) {
        return error.UnsupportedBundleSchema;
    }
    const scope = std.meta.stringToEnum(Scope, try json.requiredString(root, "scope")) orelse
        return error.UnsupportedPreparationScope;
    const definition_id = try json.requiredString(root, "definition_id");
    try json.safeIdentifier(definition_id, 256);
    const definition_digest = try json.requiredString(root, "definition_digest");
    try json.digest(definition_digest);
    const parameter_digest = try json.requiredString(root, "parameter_digest");
    try json.digest(parameter_digest);
    const entry = try json.requiredString(root, "definition_entry_path");
    try json.repositoryRelativePath(entry, false);
    if (!std.mem.endsWith(u8, entry, ".json")) return error.DefinitionPathNotJson;
    const observations = try parseObservations(arena, root, limits);
    const subjects = try parseEvidenceSubjects(arena, root, observations, limits);
    const sources = try parseSources(arena, root, limits);
    const files = try parseFiles(arena, root, limits);
    var contents = std.StringHashMap(u64).init(arena);
    var payload_bytes: u64 = 0;
    for (files) |file| {
        const content = try contents.getOrPut(file.content_id);
        if (content.found_existing and content.value_ptr.* != file.byte_length) {
            return error.ConflictingBundleContent;
        }
        content.value_ptr.* = file.byte_length;
        payload_bytes = std.math.add(u64, payload_bytes, file.byte_length) catch
            return error.BundlePayloadTooLarge;
        if (payload_bytes > limits.payload_bytes) return error.BundlePayloadTooLarge;
    }
    for (observations) |observation| {
        if (!contents.contains(observation.evidence_digest)) return error.BundleEvidenceMissing;
    }
    try validateSourceReferences(sources, subjects, contents);
    return .{
        .parsed = parsed,
        .description = .{
            .scope = scope,
            .definition_id = definition_id,
            .definition_digest = definition_digest,
            .definition_entry_path = entry,
            .parameter_digest = parameter_digest,
            .target = try parseTarget(try json.field(root, "target")),
            .observations = observations,
            .evidence_subjects = subjects,
            .sources = sources,
            .files = files,
        },
        .digest = try definition_core.canonical_json.digestValueAlloc(arena, parsed.value),
        .payload_bytes = payload_bytes,
    };
}

fn parseTarget(raw: std.json.Value) !Target {
    const map = try json.object(raw);
    const keys = &.{ "store_id", "generation" };
    try json.requireExactKeys(map, keys);
    try json.requireFields(map, keys);
    return .{
        .store_id = try json.requiredString(map, "store_id"),
        .generation = try json.requiredString(map, "generation"),
    };
}

fn parseEvidenceSubjects(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    observations: []const storage_sources.Observation,
    limits: Limits,
) ![]const EvidenceSubject {
    const raw = try json.array(try json.field(root, "evidence_subjects"));
    if (raw.items.len > limits.observations) return error.TooManyObservations;
    const subjects = try allocator.alloc(EvidenceSubject, raw.items.len);
    for (raw.items, subjects, 0..) |item, *subject, index| {
        const map = try json.object(item);
        try json.requireExactKeys(map, &.{ "observation_id", "subject" });
        try json.requireFields(map, &.{ "observation_id", "subject" });
        subject.* = .{
            .observation_id = try json.requiredString(map, "observation_id"),
            .subject = try storage_sources.parseSubject(try json.field(map, "subject")),
        };
        if (index != 0 and !evidenceSubjectLessThan({}, subjects[index - 1], subject.*)) {
            return error.NonCanonicalEvidenceSubjects;
        }
    }
    var next: usize = 0;
    for (observations) |observation| {
        const start = next;
        while (next < subjects.len and std.mem.eql(
            u8,
            observation.observation_id,
            subjects[next].observation_id,
        )) : (next += 1) {}
        if (next == start) return error.BundleEvidenceSubjectMismatch;
    }
    if (next != subjects.len) return error.BundleEvidenceSubjectMismatch;
    return subjects;
}

fn parseSources(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    limits: Limits,
) ![]const SourceWitness {
    const raw = try json.array(try json.field(root, "sources"));
    if (raw.items.len > limits.sources) return error.TooManySources;
    const sources = try allocator.alloc(SourceWitness, raw.items.len);
    var remaining = limits.files;
    for (raw.items, sources, 0..) |item, *source, index| {
        const map = try json.object(item);
        try json.requireExactKeys(map, &.{ "subject", "files" });
        try json.requireFields(map, &.{ "subject", "files" });
        var source_limits = limits;
        source_limits.files = remaining;
        source.* = .{
            .subject = try storage_sources.parseSubject(try json.field(map, "subject")),
            .files = try parseFiles(allocator, map, source_limits),
        };
        remaining -= source.files.len;
        if (index != 0 and !sourceLessThan({}, sources[index - 1], source.*)) {
            return error.NonCanonicalBundleSources;
        }
    }
    return sources;
}

fn sourceHasSubject(sources: []const SourceWitness, subject: storage_sources.Subject) bool {
    var low: usize = 0;
    var high = sources.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, sources[middle].subject.source_id, subject.source_id)) {
            .eq => high = middle,
            .lt => low = middle + 1,
            .gt => high = middle,
        }
    }
    while (low < sources.len and
        std.mem.eql(u8, sources[low].subject.source_id, subject.source_id)) : (low += 1)
    {
        const candidate = sources[low].subject;
        if (candidate.kind == subject.kind and
            optionalEqual(candidate.store_id, subject.store_id))
        {
            return true;
        }
    }
    return false;
}

fn validateSourceReferences(
    sources: []const SourceWitness,
    subjects: []const EvidenceSubject,
    contents: std.StringHashMap(u64),
) !void {
    for (sources) |source| {
        for (source.files) |file| {
            const length = contents.get(file.content_id) orelse {
                return error.BundleSourceFileMissing;
            };
            if (length != file.byte_length) return error.BundleContentMismatch;
        }
    }
    for (subjects) |subject| {
        if (!sourceHasSubject(sources, subject.subject)) return error.BundleEvidenceSubjectMismatch;
    }
}

fn parseObservations(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    limits: Limits,
) ![]const storage_sources.Observation {
    const array = try json.array(try json.field(root, "observations"));
    if (array.items.len > limits.observations) return error.TooManyObservations;
    const observations = try allocator.alloc(storage_sources.Observation, array.items.len);
    for (array.items, observations, 0..) |raw, *observation, index| {
        observation.* = try storage_sources.parseObservation(allocator, raw);
        if (index != 0 and std.mem.order(
            u8,
            observations[index - 1].observation_id,
            observation.observation_id,
        ) != .lt) return error.NonCanonicalBundleObservations;
    }
    return observations;
}

fn parseFiles(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    limits: Limits,
) ![]const File {
    const array = try json.array(try json.field(root, "files"));
    if (array.items.len > limits.files) return error.TooManyBundleFiles;
    const files = try allocator.alloc(File, array.items.len);
    for (array.items, files, 0..) |raw, *file, index| {
        const map = try json.object(raw);
        const keys = &.{ "path", "content_id", "byte_length", "definition_closure" };
        try json.requireExactKeys(map, keys);
        try json.requireFields(map, &.{ "path", "content_id", "byte_length" });
        const path = try json.requiredString(map, "path");
        try json.repositoryRelativePath(path, false);
        const content_id = try json.requiredString(map, "content_id");
        try json.digest(content_id);
        const closure = try json.optionalString(map, "definition_closure");
        if (closure) |digest| try json.digest(digest);
        file.* = .{
            .path = path,
            .content_id = content_id,
            .byte_length = try json.unsigned64(try json.field(map, "byte_length")),
            .definition_closure = closure,
        };
        if (index != 0 and std.mem.order(u8, files[index - 1].path, path) != .lt) {
            return error.NonCanonicalBundleFiles;
        }
    }
    return files;
}

pub fn encode(allocator: std.mem.Allocator, supplied: Description, limits: Limits) ![]u8 {
    try limits.validate();
    if (supplied.files.len > limits.files) return error.TooManyBundleFiles;
    if (supplied.observations.len > limits.observations) return error.TooManyObservations;
    if (supplied.evidence_subjects.len > limits.observations) return error.TooManyObservations;
    const files = try allocator.dupe(File, supplied.files);
    defer allocator.free(files);
    std.mem.sort(File, files, {}, fileLessThan);
    const observations = try allocator.dupe(storage_sources.Observation, supplied.observations);
    defer allocator.free(observations);
    std.mem.sort(storage_sources.Observation, observations, {}, observationLessThan);
    const count = try coalesceObservations(observations);
    var normalized = supplied;
    normalized.files = files;
    normalized.observations = observations[0..count];
    const subjects = try allocator.dupe(EvidenceSubject, supplied.evidence_subjects);
    defer allocator.free(subjects);
    std.mem.sort(EvidenceSubject, subjects, {}, evidenceSubjectLessThan);
    normalized.evidence_subjects = subjects[0..try coalesceEvidenceSubjects(subjects)];
    var source_arena = std.heap.ArenaAllocator.init(allocator);
    defer source_arena.deinit();
    normalized.sources = try normalizeSources(source_arena.allocator(), supplied.sources, limits);
    const buffer = try allocator.alloc(u8, limits.manifest_bytes);
    defer allocator.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    std.json.Stringify.value(normalized, .{
        .emit_null_optional_fields = false,
    }, &writer) catch return error.BundleManifestTooLarge;
    var manifest = try parse(allocator, writer.buffered(), limits);
    defer manifest.deinit();
    const canonical = try definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        manifest.parsed.value,
    );
    errdefer allocator.free(canonical);
    if (canonical.len > limits.manifest_bytes) return error.BundleManifestTooLarge;
    return canonical;
}

fn fileLessThan(_: void, left: File, right: File) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

fn evidenceSubjectLessThan(_: void, left: EvidenceSubject, right: EvidenceSubject) bool {
    return switch (std.mem.order(u8, left.observation_id, right.observation_id)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, left.subject.source_id, right.subject.source_id),
    };
}

fn sourceLessThan(_: void, left: SourceWitness, right: SourceWitness) bool {
    return compareSources(left, right) == .lt;
}

pub fn compareSources(left: SourceWitness, right: SourceWitness) std.math.Order {
    inline for (.{ "source_id", "locator" }) |field| {
        const order = std.mem.order(u8, @field(left.subject, field), @field(right.subject, field));
        if (order != .eq) return order;
    }
    const kind = std.mem.order(u8, @tagName(left.subject.kind), @tagName(right.subject.kind));
    if (kind != .eq) return kind;
    const store = optionalOrder(left.subject.store_id, right.subject.store_id);
    if (store != .eq) return store;
    const shared = @min(left.files.len, right.files.len);
    for (left.files[0..shared], right.files[0..shared]) |a, b| {
        inline for (.{ "path", "content_id" }) |field| {
            const order = std.mem.order(u8, @field(a, field), @field(b, field));
            if (order != .eq) return order;
        }
        const bytes = std.math.order(a.byte_length, b.byte_length);
        if (bytes != .eq) return bytes;
        const closure = optionalOrder(a.definition_closure, b.definition_closure);
        if (closure != .eq) return closure;
    }
    return std.math.order(left.files.len, right.files.len);
}

fn optionalOrder(left: ?[]const u8, right: ?[]const u8) std.math.Order {
    if (left == null) return if (right == null) .eq else .lt;
    if (right == null) return .gt;
    return std.mem.order(u8, left.?, right.?);
}

fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if ((left == null) != (right == null)) return false;
    return if (left) |value| std.mem.eql(u8, value, right.?) else true;
}

fn sameSubject(left: storage_sources.Subject, right: storage_sources.Subject) bool {
    return left.kind == right.kind and std.mem.eql(u8, left.source_id, right.source_id) and
        std.mem.eql(u8, left.locator, right.locator) and
        optionalEqual(left.store_id, right.store_id);
}

fn coalesceEvidenceSubjects(subjects: []EvidenceSubject) !usize {
    var count: usize = 0;
    for (subjects) |subject| {
        if (count != 0 and !evidenceSubjectLessThan({}, subjects[count - 1], subject)) {
            if (!sameSubject(subjects[count - 1].subject, subject.subject)) {
                return error.ConflictingObservationSubject;
            }
            continue;
        }
        subjects[count] = subject;
        count += 1;
    }
    return count;
}

fn normalizeSources(
    allocator: std.mem.Allocator,
    supplied: []const SourceWitness,
    limits: Limits,
) ![]const SourceWitness {
    if (supplied.len > limits.sources) return error.TooManySources;
    var remaining = limits.files;
    for (supplied) |source| {
        if (source.files.len > remaining) return error.TooManyBundleFiles;
        remaining -= source.files.len;
    }
    const sources = try allocator.dupe(SourceWitness, supplied);
    for (sources) |*source| {
        const files = try allocator.dupe(File, source.files);
        std.mem.sort(File, files, {}, fileLessThan);
        source.files = files;
    }
    std.mem.sort(SourceWitness, sources, {}, sourceLessThan);
    var count: usize = 0;
    for (sources) |source| {
        if (count != 0 and !sourceLessThan({}, sources[count - 1], source)) {
            continue;
        }
        sources[count] = source;
        count += 1;
    }
    return sources[0..count];
}

fn observationLessThan(
    _: void,
    left: storage_sources.Observation,
    right: storage_sources.Observation,
) bool {
    return std.mem.lessThan(u8, left.observation_id, right.observation_id);
}

fn coalesceObservations(observations: []storage_sources.Observation) !usize {
    var count: usize = 0;
    for (observations) |observation| {
        if (count != 0 and std.mem.eql(
            u8,
            observations[count - 1].observation_id,
            observation.observation_id,
        )) {
            const previous = observations[count - 1];
            if (!std.mem.eql(u8, previous.evidence_locator, observation.evidence_locator) or
                !std.mem.eql(u8, previous.evidence_digest, observation.evidence_digest) or
                !std.mem.eql(u8, previous.evidence_pointer, observation.evidence_pointer) or
                !previous.binding.eql(observation.binding))
            {
                return error.ConflictingObservationId;
            }
            continue;
        }
        observations[count] = observation;
        count += 1;
    }
    return count;
}

pub const CapturedFile = struct {
    descriptor: File,
    content: []const u8,
};

pub const Captured = struct {
    arena: std.heap.ArenaAllocator,
    manifest: []const u8,
    identity: []const u8,
    files: []const CapturedFile,
    payload_bytes: u64,

    pub fn deinit(self: *Captured) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const PublishOptions = struct {
    budget: *durable_store.ReservationBudget,
    budget_id: []const u8,
    free_space: durable_store.ReservationFreeSpaceObservation,
    owner: durable_store.Owner,
    limits: Limits,
    preparation: ?*const storage_preparation.Publication = null,
};

pub const Published = struct {
    receipt: durable_store.ReservedTransactionReceipt,
    verification_error: ?anyerror = null,

    pub fn deinit(self: *Published, allocator: std.mem.Allocator) void {
        self.receipt.transaction.deinit(allocator);
        self.* = undefined;
    }
};

pub const Reservation = struct {
    arena: std.heap.ArenaAllocator,
    budget: *durable_store.ReservationBudget,
    request: durable_store.ReservationRequest,
    receipt: durable_store.ReservationReceipt,

    pub fn acquire(
        allocator: std.mem.Allocator,
        target: *const storage_root.SourceRoot,
        operation_id: []const u8,
        options: PublishOptions,
    ) !Reservation {
        const charge = try durable_store.ReservationBudget.transactionCharge(
            try std.math.add(u64, options.limits.payload_bytes, options.limits.manifest_bytes),
            options.limits.manifest_bytes,
        );
        return acquireCharge(allocator, target, operation_id, options, charge);
    }

    pub fn acquireCharge(
        allocator: std.mem.Allocator,
        target: *const storage_root.SourceRoot,
        operation_id: []const u8,
        options: PublishOptions,
        charge: durable_store.ReservationCharge,
    ) !Reservation {
        try options.limits.validate();
        const store_id = target.store_id orelse return error.UnmanagedBundleTarget;
        for ([_][]const u8{ operation_id, options.budget_id, store_id }) |identity| {
            if (identity.len > durable_store.ReservationBudget.max_identity_bytes) {
                return error.InvalidReservationIdentity;
            }
        }
        try target.revalidateControl();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const request: durable_store.ReservationRequest = .{
            .budget_id = try owned.dupe(u8, options.budget_id),
            .store_id = try owned.dupe(u8, store_id),
            .operation_id = try owned.dupe(u8, operation_id),
            .charge = charge,
        };
        const receipt = try options.budget.reserve(allocator, request, options.free_space);
        return .{
            .arena = arena,
            .budget = options.budget,
            .request = request,
            .receipt = receipt,
        };
    }

    pub fn beginPublication(
        self: *const Reservation,
        allocator: std.mem.Allocator,
        target: *const storage_root.SourceRoot,
        options: PublishOptions,
        identity: [32]u8,
    ) !PublicationState {
        try self.validate(target, options);
        return resumePublication(allocator, target, options, self.request, self.receipt, identity);
    }

    pub fn associateSource(
        self: *const Reservation,
        allocator: std.mem.Allocator,
        target: *const storage_root.SourceRoot,
        options: PublishOptions,
    ) !void {
        try self.validate(target, options);
        const scope = target.scope() orelse return error.StorageRootMissing;
        const control = try storage_root.controlPathAlloc(&scope, allocator, ".");
        defer allocator.free(control);
        const path = try std.fs.path.join(allocator, &.{ control, ".transactions" });
        defer allocator.free(path);
        try self.budget.associateSource(allocator, scope.fs, path, .{
            .request = self.request,
            .reservation = self.receipt,
            .free_space = options.free_space,
            .transaction = .{ .owner = options.owner },
        });
    }

    pub fn validate(
        self: *const Reservation,
        target: *const storage_root.SourceRoot,
        options: PublishOptions,
    ) !void {
        if (self.budget != options.budget or
            !std.mem.eql(u8, self.request.budget_id, options.budget_id) or
            !std.mem.eql(u8, self.request.store_id, target.store_id orelse ""))
        {
            return error.ReservationIdentityMismatch;
        }
        try target.revalidateControl();
    }

    pub fn deinit(self: *Reservation) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const PublicationState = union(enum) {
    ready: durable_store.ReservationReceipt,
    terminal: durable_store.ReservedTransactionReceipt,
};

pub fn publishCaptured(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    captured: *const Captured,
    options: PublishOptions,
) !Published {
    var publication = try Publication.init(allocator, target, captured, options.limits);
    defer publication.deinit();
    const request: durable_store.ReservationRequest = .{
        .budget_id = options.budget_id,
        .store_id = target.store_id.?,
        .operation_id = captured.identity,
        .charge = try durable_store.ReservationBudget.transactionCharge(
            try std.math.add(u64, publication.payload_bytes, captured.manifest.len),
            captured.manifest.len,
        ),
    };
    const reserved = try options.budget.reserve(allocator, request, options.free_space);
    return commitPublication(&publication, options, request, reserved, null);
}

pub fn publishReservedCaptured(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    captured: *const Captured,
    options: PublishOptions,
    reservation: *const Reservation,
) !Published {
    try reservation.validate(target, options);
    var publication = try Publication.init(allocator, target, captured, options.limits);
    defer publication.deinit();
    var identity: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(captured.identity, &identity, .{});
    return commitPublication(
        &publication,
        options,
        reservation.request,
        reservation.receipt,
        identity,
    );
}

fn commitPublication(
    publication: *Publication,
    options: PublishOptions,
    request: durable_store.ReservationRequest,
    initial: durable_store.ReservationReceipt,
    identity: ?[32]u8,
) !Published {
    const allocator = publication.scratch_allocator;
    const scope = publication.target.scope().?;
    const reserved = switch (try resumePublication(
        allocator,
        publication.target,
        options,
        request,
        initial,
        identity,
    )) {
        .ready => |receipt| receipt,
        .terminal => |receipt| return finishPublication(publication, receipt),
    };
    try publication.planWrites();
    if (options.preparation) |held| {
        try held.include(publication.arena.allocator(), &publication.mutations);
    }
    const receipt = try options.budget.commitReserved(
        allocator,
        scope.fs,
        publication.transactions_path,
        publication.mutations.items,
        .{
            .request = request,
            .reservation = reserved,
            .free_space = options.free_space,
            .target_classes = &.{.{ .path = publication.manifest_target, .class = .metadata }},
            .transaction = .{ .owner = options.owner },
            .custody = if (options.preparation) |held| try held.nativeCustody() else null,
            .publication_identity = identity,
        },
    );
    return finishPublication(publication, receipt);
}

fn resumePublication(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    options: PublishOptions,
    request: durable_store.ReservationRequest,
    initial: durable_store.ReservationReceipt,
    identity: ?[32]u8,
) !PublicationState {
    if (identity == null and
        (!initial.reused or (options.preparation != null and initial.status == .reserved)))
    {
        return .{ .ready = initial };
    }
    const receipt = try reconcilePublication(allocator, target, options, request, identity) orelse
        return .{ .ready = initial };
    if (receipt.semantic != .aborted or receipt.accounting_error != null or
        options.preparation != null)
    {
        return .{ .terminal = receipt };
    }
    var aborted = receipt;
    defer aborted.transaction.deinit(allocator);
    const fs = target.scope().?.fs;
    const reserved = if (identity) |selected| try options.budget.restartAbortedPublication(
        allocator,
        fs,
        request,
        options.free_space,
        selected,
    ) else try options.budget.restartAborted(allocator, fs, request, options.free_space);
    return .{ .ready = reserved };
}

fn reconcilePublication(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    options: PublishOptions,
    request: durable_store.ReservationRequest,
    identity: ?[32]u8,
) !?durable_store.ReservedTransactionReceipt {
    const fs = target.scope().?.fs;
    if (identity) |selected| {
        if (options.preparation != null) {
            return options.budget.observedPublication(allocator, fs, request, selected);
        }
        return options.budget.reconcilePublication(
            allocator,
            fs,
            request,
            options.free_space,
            selected,
        ) catch |err| switch (err) {
            error.ReservationUnbound => null,
            else => return err,
        };
    }
    return options.budget.reconcile(allocator, fs, request, options.free_space) catch |err|
        switch (err) {
            error.ReservationUnbound => null,
            else => return err,
        };
}

fn finishPublication(
    publication: *Publication,
    receipt: durable_store.ReservedTransactionReceipt,
) Published {
    var result: Published = .{ .receipt = receipt };
    if (receipt.semantic == .committed) {
        publication.verify() catch |err| {
            result.verification_error = err;
        };
    }
    return result;
}

pub const Publication = struct {
    arena: std.heap.ArenaAllocator,
    scratch_allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    captured: *const Captured,
    objects: std.StringHashMapUnmanaged([]const u8),
    control_path: []const u8,
    transactions_path: []const u8,
    manifest_path: []const u8,
    manifest_target: []const u8,
    payload_bytes: u64,
    mutations: std.ArrayList(durable_store.TransactionMutation) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        target: *const storage_root.SourceRoot,
        captured: *const Captured,
        limits: Limits,
    ) !Publication {
        const store_id = target.store_id orelse return error.UnmanagedBundleTarget;
        const scope = target.scope() orelse return error.StorageRootMissing;
        try target.revalidateControl();
        var manifest = try parse(allocator, captured.manifest, limits);
        defer manifest.deinit();
        if (!std.mem.eql(u8, manifest.digest, captured.identity) or
            !std.mem.eql(u8, store_id, manifest.description.target.store_id) or
            manifest.description.files.len != captured.files.len)
        {
            return error.BundleIdentityMismatch;
        }
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var objects: std.StringHashMapUnmanaged([]const u8) = .empty;
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        var payload_bytes: u64 = 0;
        for (captured.files) |file| {
            if ((try seen.getOrPut(file.descriptor.path)).found_existing) {
                return error.BundleIdentityMismatch;
            }
            const descriptor = try validateCapturedFile(
                allocator,
                manifest.description.files,
                file,
            );
            const key = try arena.allocator().dupe(u8, descriptor.content_id);
            const entry = try objects.getOrPut(arena.allocator(), key);
            if (!entry.found_existing) {
                entry.value_ptr.* = file.content;
                payload_bytes = try std.math.add(u64, payload_bytes, file.content.len);
            } else if (!std.mem.eql(u8, entry.value_ptr.*, file.content)) {
                return error.BundleContentMismatch;
            }
        }
        try verifyEvidence(allocator, manifest.description, objects);
        const path = try manifestPath(arena.allocator(), captured.identity);
        const control_path = try storage_root.controlPathAlloc(&scope, arena.allocator(), ".");
        const transactions_path = try std.fs.path.join(
            arena.allocator(),
            &.{ control_path, ".transactions" },
        );
        const manifest_target = try std.fs.path.join(arena.allocator(), &.{ control_path, path });
        return .{
            .arena = arena,
            .scratch_allocator = allocator,
            .target = target,
            .captured = captured,
            .objects = objects,
            .control_path = control_path,
            .transactions_path = transactions_path,
            .manifest_path = path,
            .manifest_target = manifest_target,
            .payload_bytes = payload_bytes,
        };
    }

    pub fn deinit(self: *Publication) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn planWrites(self: *Publication) !void {
        var objects = self.objects.iterator();
        while (objects.next()) |entry| {
            const path = try objectPath(self.arena.allocator(), entry.key_ptr.*);
            try self.planFile(path, entry.value_ptr.*);
        }
        try self.planFile(self.manifest_path, self.captured.manifest);
    }

    fn planFile(self: *Publication, path: []const u8, content: []const u8) !void {
        const digest = try definition_core.canonical_json.digestBytesAlloc(
            self.arena.allocator(),
            content,
        );
        const exists = self.existingMatches(path, content) catch |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        };
        try self.mutations.append(self.arena.allocator(), .{
            .path = try std.fs.path.join(self.arena.allocator(), &.{ self.control_path, path }),
            .text = if (exists) "" else content,
            .expectation = .{
                .expected_exists = exists,
                .expected_digest = if (exists) digest else null,
            },
            .content_mode = .raw,
            .max_bytes = content.len,
            .action = if (exists) .check_only else .write,
            .expected_digest_after = digest,
        });
    }

    fn existingMatches(self: *Publication, path: []const u8, content: []const u8) !bool {
        const file = try self.target.openControlFile(path);
        defer file.close(self.target.io);
        var reader = file.reader(self.target.io, &.{});
        reader.mode = .positional_simple;
        const bytes = try reader.interface.allocRemaining(
            self.scratch_allocator,
            .limited(content.len),
        );
        defer self.scratch_allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, content)) return error.BundleContentMismatch;
        return true;
    }

    pub fn verify(self: *Publication) !void {
        try self.target.revalidateControl();
        _ = try self.existingMatches(self.manifest_path, self.captured.manifest);
        var objects = self.objects.iterator();
        while (objects.next()) |entry| {
            const path = try objectPath(self.scratch_allocator, entry.key_ptr.*);
            defer self.scratch_allocator.free(path);
            _ = try self.existingMatches(path, entry.value_ptr.*);
        }
    }
};

pub fn validateCapturedFile(
    allocator: std.mem.Allocator,
    files: []const File,
    captured: CapturedFile,
) !File {
    var low: usize = 0;
    var high = files.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, captured.descriptor.path, files[middle].path)) {
            .lt => high = middle,
            .gt => low = middle + 1,
            .eq => {
                const file = files[middle];
                if (file.byte_length != captured.content.len) return error.BundleContentMismatch;
                const digest = try definition_core.canonical_json.digestBytesAlloc(
                    allocator,
                    captured.content,
                );
                defer allocator.free(digest);
                if (!std.mem.eql(u8, file.content_id, digest)) return error.BundleContentMismatch;
                if (file.definition_closure) |closure| {
                    var archive = try definition_archive.parse(
                        allocator,
                        captured.content,
                        closure,
                    );
                    defer archive.deinit(allocator);
                }
                return file;
            },
        }
    }
    return error.BundleIdentityMismatch;
}

fn manifestPath(allocator: std.mem.Allocator, identity: []const u8) ![]u8 {
    try json.digest(identity);
    return allocator.print(".preservation/manifests/{s}.json", .{identity[7..]});
}

fn objectPath(allocator: std.mem.Allocator, identity: []const u8) ![]u8 {
    try json.digest(identity);
    return allocator.print(".preservation/objects/{s}", .{identity[7..]});
}

pub fn loadPublished(
    allocator: std.mem.Allocator,
    source: *const storage_root.SourceRoot,
    identity: []const u8,
    limits: Limits,
) !Captured {
    try limits.validate();
    try source.revalidateControl();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const path = try manifestPath(owned, identity);
    const bytes = try readBundleFile(owned, source, path, limits.manifest_bytes);
    var manifest = try parse(allocator, bytes, limits);
    defer manifest.deinit();
    if (!std.mem.eql(u8, manifest.digest, identity)) return error.BundleIdentityMismatch;
    var objects = std.StringHashMap([]const u8).init(allocator);
    defer objects.deinit();
    const files = try owned.alloc(CapturedFile, manifest.description.files.len);
    for (manifest.description.files, files) |descriptor, *file| {
        const object = try objects.getOrPut(descriptor.content_id);
        if (!object.found_existing) {
            const object_path = try objectPath(owned, descriptor.content_id);
            object.value_ptr.* = try readBundleFile(
                owned,
                source,
                object_path,
                descriptor.byte_length,
            );
        }
        const content = object.value_ptr.*;
        _ = try validateCapturedFile(allocator, manifest.description.files, .{
            .descriptor = descriptor,
            .content = content,
        });
        file.* = .{ .descriptor = try copyDescriptor(owned, descriptor), .content = content };
    }
    try verifyEvidence(allocator, manifest.description, objects);
    try source.revalidateControl();
    const owned_identity = try owned.dupe(u8, manifest.digest);
    return .{
        .arena = arena,
        .manifest = bytes,
        .identity = owned_identity,
        .files = files,
        .payload_bytes = manifest.payload_bytes,
    };
}

fn readBundleFile(
    allocator: std.mem.Allocator,
    source: *const storage_root.SourceRoot,
    path: []const u8,
    maximum: u64,
) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var scratch: [8192]u8 = undefined;
    _ = try storage_preparation.captureControlFile(
        source,
        path,
        &output.writer,
        maximum,
        &scratch,
    );
    return output.toOwnedSlice();
}

pub fn verifyEvidence(
    allocator: std.mem.Allocator,
    description: Description,
    objects: anytype,
) !void {
    var next: usize = 0;
    for (description.observations) |observation| {
        const bytes = objects.get(observation.evidence_digest) orelse {
            return error.BundleEvidenceMissing;
        };
        const start = next;
        while (next < description.evidence_subjects.len and std.mem.eql(
            u8,
            observation.observation_id,
            description.evidence_subjects[next].observation_id,
        )) : (next += 1) {
            try storage_sources.verifyBoundObservationEvidence(
                allocator,
                observation,
                description.evidence_subjects[next].subject,
                bytes,
            );
        }
        if (next == start) return error.BundleEvidenceSubjectMismatch;
    }
    if (next != description.evidence_subjects.len) return error.BundleEvidenceSubjectMismatch;
}

fn copyDescriptor(allocator: std.mem.Allocator, descriptor: File) !File {
    return .{
        .path = try allocator.dupe(u8, descriptor.path),
        .content_id = try allocator.dupe(u8, descriptor.content_id),
        .byte_length = descriptor.byte_length,
        .definition_closure = if (descriptor.definition_closure) |closure|
            try allocator.dupe(u8, closure)
        else
            null,
    };
}

pub const DeclaredOptions = struct {
    closure: *const definition_core.Closure,
    entry_path: []const u8,
    target: Target,
    evidence: ?*const storage_source_admission.RootAdmission = null,
    limits: Limits,
};

pub const DeclaredInput = struct {
    snapshot: *storage_preparation.DeclaredSnapshot,
    evidence: *const storage_source_admission.RootAdmission,
};

pub const GroupOptions = struct {
    closure: *const definition_core.Closure,
    entry_path: []const u8,
    target: Target,
    established_target: ?usize = null,
    max_capture_bytes: u64,
    limits: Limits,
};

pub fn captureDeclaredGroup(
    allocator: std.mem.Allocator,
    inputs: []const DeclaredInput,
    options: GroupOptions,
) !Captured {
    try options.limits.validate();
    if (inputs.len == 0) return error.NoPreparationSources;
    if (inputs.len > options.limits.sources) return error.TooManySources;
    if (options.established_target) |index| {
        if (index >= inputs.len) return error.InvalidPreparationTarget;
    }
    const ordered = try allocator.dupe(DeclaredInput, inputs);
    defer allocator.free(ordered);
    std.mem.sort(DeclaredInput, ordered, {}, inputLessThan);
    const selected = try selectGroup(allocator, ordered, if (options.established_target) |index|
        inputs[index].snapshot
    else
        null, options.limits.observations);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var group: GroupCapture = .{
        .allocator = arena.allocator(),
        .scratch = allocator,
        .capture = .{
            .allocator = arena.allocator(),
            .scratch_allocator = allocator,
            .snapshot = ordered[selected].snapshot,
            .limits = options.limits,
            .by_path = .init(arena.allocator()),
        },
    };
    var remaining = options.max_capture_bytes;
    try group.include(ordered[selected], options, true, &remaining);
    for (ordered, 0..) |input, index| {
        if (index != selected) try group.include(input, options, false, &remaining);
    }
    for (ordered) |input| try input.evidence.requireSource(input.snapshot.source);
    return group.finish(&arena, options);
}

fn inputLessThan(_: void, left: DeclaredInput, right: DeclaredInput) bool {
    return std.mem.lessThan(
        u8,
        left.evidence.descriptor().source_id,
        right.evidence.descriptor().source_id,
    );
}

fn selectGroup(
    allocator: std.mem.Allocator,
    ordered: []const DeclaredInput,
    target: ?*storage_preparation.DeclaredSnapshot,
    max_observations: usize,
) !usize {
    const snapshots = try allocator.alloc(*const storage_preparation.DeclaredSnapshot, ordered.len);
    defer allocator.free(snapshots);
    var established: ?usize = null;
    var remaining = max_observations;
    for (ordered, snapshots, 0..) |input, *snapshot, index| {
        if (index != 0 and !inputLessThan({}, ordered[index - 1], input)) {
            return error.DuplicateSourceId;
        }
        try input.evidence.requireSource(input.snapshot.source);
        const count = input.evidence.evidence.len;
        if (count > remaining) return error.TooManyObservations;
        remaining -= count;
        snapshot.* = input.snapshot;
        if (input.snapshot == target) established = index;
    }
    return storage_preparation.selectBoundHistory(snapshots, established);
}

const GroupCapture = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    capture: Capture,
    contents: std.StringHashMapUnmanaged(void) = .empty,
    observations: std.ArrayList(storage_sources.Observation) = .empty,
    subjects: std.ArrayList(EvidenceSubject) = .empty,
    sources: std.ArrayList(SourceWitness) = .empty,
    source_references: usize = 0,

    fn include(
        self: *GroupCapture,
        input: DeclaredInput,
        options: GroupOptions,
        selected: bool,
        remaining: *u64,
    ) !void {
        var limits = options.limits;
        limits.payload_bytes = @min(limits.payload_bytes, remaining.*);
        var captured = try captureDeclared(self.scratch, input.snapshot, .{
            .closure = options.closure,
            .entry_path = options.entry_path,
            .target = options.target,
            .evidence = input.evidence,
            .limits = limits,
        });
        defer captured.deinit();
        remaining.* -= captured.payload_bytes;
        var manifest = try parse(self.scratch, captured.manifest, limits);
        defer manifest.deinit();
        const original = manifest.description.sources[0];
        if (original.files.len > options.limits.files - self.source_references) {
            return error.TooManyBundleFiles;
        }
        self.source_references += original.files.len;
        for (captured.files) |file| try self.includeFile(file, selected);
        try self.observations.appendSlice(self.allocator, input.evidence.descriptor().observations);
        for (input.evidence.evidence) |item| {
            try self.subjects.append(self.allocator, .{
                .observation_id = item.observation.observation_id,
                .subject = item.subject,
            });
        }
        const files = try self.allocator.alloc(File, original.files.len);
        for (original.files, files) |file, *copy| copy.* = try copyDescriptor(self.allocator, file);
        const descriptor = input.evidence.descriptor();
        try self.sources.append(self.allocator, .{
            .subject = .{
                .source_id = descriptor.source_id,
                .kind = descriptor.kind,
                .locator = descriptor.locator,
                .store_id = descriptor.store_id,
            },
            .files = files,
        });
    }

    fn includeFile(self: *GroupCapture, file: CapturedFile, selected: bool) !void {
        if (selected) {
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(file.content, &hash, .{});
            try self.capture.add(
                file.descriptor.path,
                file.content,
                file.descriptor.definition_closure,
                hash,
            );
        } else if (!self.contents.contains(file.descriptor.content_id)) {
            try self.capture.visitEvidence(file.content);
        }
        if (!self.contents.contains(file.descriptor.content_id)) {
            const key = try self.allocator.dupe(u8, file.descriptor.content_id);
            try self.contents.put(self.allocator, key, {});
        }
    }

    fn finish(
        self: *GroupCapture,
        arena: *std.heap.ArenaAllocator,
        options: GroupOptions,
    ) !Captured {
        const descriptors = try self.allocator.alloc(File, self.capture.files.items.len);
        for (self.capture.files.items, descriptors) |file, *descriptor| {
            descriptor.* = file.descriptor;
        }
        const snapshot = self.capture.snapshot;
        const bytes = try encode(self.allocator, .{
            .scope = .declared,
            .definition_id = snapshot.definition_id,
            .definition_digest = &snapshot.definition_digest,
            .definition_entry_path = options.entry_path,
            .parameter_digest = &snapshot.parameter_digest,
            .target = options.target,
            .observations = self.observations.items,
            .evidence_subjects = self.subjects.items,
            .sources = self.sources.items,
            .files = descriptors,
        }, options.limits);
        var manifest = try parse(self.scratch, bytes, options.limits);
        defer manifest.deinit();
        const identity = try self.allocator.dupe(u8, manifest.digest);
        const files = try self.capture.files.toOwnedSlice(self.allocator);
        return .{
            .arena = arena.*,
            .manifest = bytes,
            .identity = identity,
            .files = files,
            .payload_bytes = manifest.payload_bytes,
        };
    }
};

pub fn captureDeclared(
    allocator: std.mem.Allocator,
    snapshot: *storage_preparation.DeclaredSnapshot,
    options: DeclaredOptions,
) !Captured {
    try options.limits.validate();
    if (options.evidence) |evidence| try evidence.requireSource(snapshot.source);
    if (!std.mem.eql(u8, options.closure.digestSlice(), &snapshot.definition_digest)) {
        return error.PreparationDefinitionMismatch;
    }
    var plan = try definition.compile(allocator, options.closure, options.entry_path);
    defer plan.deinit(allocator);
    if (!std.mem.eql(u8, plan.id, snapshot.definition_id)) {
        return error.PreparationDefinitionMismatch;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var capture: Capture = .{
        .allocator = arena.allocator(),
        .scratch_allocator = allocator,
        .snapshot = snapshot,
        .limits = options.limits,
        .by_path = .init(arena.allocator()),
    };
    try snapshot.visitFiles(allocator, &capture);
    try snapshot.visitRecoveryEvidence(&capture);
    try capture.includeSelectedClosure(options);
    const sources = try capture.sourceWitness(options.evidence);
    const evidence = try capture.includeEvidence(options.evidence);
    const descriptors = try allocator.alloc(File, capture.files.items.len);
    defer allocator.free(descriptors);
    for (capture.files.items, descriptors) |file, *descriptor| descriptor.* = file.descriptor;
    const bytes = try encode(allocator, .{
        .scope = .declared,
        .definition_id = snapshot.definition_id,
        .definition_digest = &snapshot.definition_digest,
        .definition_entry_path = options.entry_path,
        .parameter_digest = &snapshot.parameter_digest,
        .target = options.target,
        .observations = if (options.evidence) |admitted|
            admitted.descriptor().observations
        else
            &.{},
        .evidence_subjects = evidence,
        .sources = sources,
        .files = descriptors,
    }, options.limits);
    defer allocator.free(bytes);
    var manifest = try parse(allocator, bytes, options.limits);
    defer manifest.deinit();
    const owned_manifest = try arena.allocator().dupe(u8, bytes);
    const identity = try arena.allocator().dupe(u8, manifest.digest);
    const files = try capture.files.toOwnedSlice(arena.allocator());
    return .{
        .arena = arena,
        .manifest = owned_manifest,
        .identity = identity,
        .files = files,
        .payload_bytes = manifest.payload_bytes,
    };
}

const Capture = struct {
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    snapshot: *storage_preparation.DeclaredSnapshot,
    limits: Limits,
    files: std.ArrayList(CapturedFile) = .empty,
    by_path: std.StringHashMap(usize),
    payload_bytes: u64 = 0,

    fn sourceWitness(
        self: *Capture,
        evidence: ?*const storage_source_admission.RootAdmission,
    ) ![]const SourceWitness {
        const admitted = evidence orelse return &.{};
        const files = try self.allocator.alloc(File, self.files.items.len);
        for (self.files.items, files) |file, *descriptor| descriptor.* = file.descriptor;
        const descriptor = admitted.descriptor();
        const result = try self.allocator.alloc(SourceWitness, 1);
        result[0] = .{
            .subject = .{
                .source_id = descriptor.source_id,
                .kind = descriptor.kind,
                .locator = descriptor.locator,
                .store_id = descriptor.store_id,
            },
            .files = files,
        };
        return result;
    }

    pub fn visit(self: *Capture, dependency: storage_preparation.FileDependency) !void {
        if (self.by_path.get(dependency.path)) |index| {
            const descriptor = self.files.items[index].descriptor;
            if (descriptor.byte_length > dependency.max_bytes) return error.CaptureLimitExceeded;
            const matches = switch (dependency.identity) {
                .native_recovery => true,
                .content => |expected| std.mem.eql(u8, descriptor.content_id, expected),
                .definition_closure => |expected| if (descriptor.definition_closure) |actual|
                    std.mem.eql(u8, actual, expected)
                else
                    false,
            };
            if (!matches) return error.PreparationSourceChanged;
            return;
        }
        if (self.files.items.len == self.limits.files) return error.TooManyBundleFiles;
        const remaining = self.limits.payload_bytes - self.payload_bytes;
        var output = std.Io.Writer.Allocating.init(self.scratch_allocator);
        defer output.deinit();
        var scratch: [8192]u8 = undefined;
        const result = try storage_preparation.captureControlFile(
            self.snapshot.source,
            dependency.path,
            &output.writer,
            @min(dependency.max_bytes, remaining),
            &scratch,
        );
        try dependency.validateCaptured(self.scratch_allocator, output.written());
        try self.add(dependency.path, output.written(), switch (dependency.identity) {
            .content, .native_recovery => null,
            .definition_closure => |digest| digest,
        }, result.sha256);
    }

    pub fn visitEvidence(self: *Capture, bytes: []const u8) !void {
        try appendEvidence(self, bytes);
    }

    fn add(
        self: *Capture,
        path: []const u8,
        content: []const u8,
        closure: ?[]const u8,
        hash: [32]u8,
    ) !void {
        try appendCapturedFile(self, path, content, closure, hash);
    }

    fn includeSelectedClosure(self: *Capture, options: DeclaredOptions) !void {
        const path = try definition_archive.pathAlloc(
            &self.snapshot.scope.?,
            self.scratch_allocator,
            ".",
            options.closure.digestSlice(),
        );
        defer self.scratch_allocator.free(path);
        var relative = path;
        while (std.mem.startsWith(u8, relative, "./")) relative = relative[2..];
        if (self.by_path.contains(relative)) return;
        const bytes = try definition_archive.renderAlloc(
            self.scratch_allocator,
            self.snapshot.definition_id,
            options.entry_path,
            options.closure,
        );
        defer self.scratch_allocator.free(bytes);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        try self.add(relative, bytes, options.closure.digestSlice(), hash);
    }

    fn includeEvidence(
        self: *Capture,
        admitted: ?*const storage_source_admission.RootAdmission,
    ) ![]const EvidenceSubject {
        const admission = admitted orelse return &.{};
        if (admission.evidence.len > self.limits.observations) return error.TooManyObservations;
        const subjects = try self.allocator.alloc(EvidenceSubject, admission.evidence.len);
        for (admission.evidence, subjects) |item, *subject| {
            try storage_sources.verifyBoundObservationEvidence(
                self.scratch_allocator,
                item.observation,
                item.subject,
                item.bytes,
            );
            try self.visitEvidence(item.bytes);
            subject.* = .{
                .observation_id = item.observation.observation_id,
                .subject = item.subject,
            };
        }
        try admission.requireSource(self.snapshot.source);
        return subjects;
    }
};

fn appendEvidence(self: anytype, bytes: []const u8) !void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const path = try self.scratch_allocator.print(
        ".evidence/{s}.json",
        .{std.fmt.bytesToHex(hash, .lower)},
    );
    defer self.scratch_allocator.free(path);
    if (self.by_path.get(path)) |index| {
        if (!std.mem.eql(u8, self.files.items[index].content, bytes)) {
            return error.ConflictingBundleContent;
        }
        return;
    }
    try appendCapturedFile(self, path, bytes, null, hash);
}

fn appendCapturedFile(
    self: anytype,
    path: []const u8,
    content: []const u8,
    closure: ?[]const u8,
    hash: [32]u8,
) !void {
    if (self.files.items.len == self.limits.files) return error.TooManyBundleFiles;
    if (content.len > self.limits.payload_bytes - self.payload_bytes) {
        return error.BundlePayloadTooLarge;
    }
    const hex = std.fmt.bytesToHex(hash, .lower);
    const digest = try self.allocator.print("sha256:{s}", .{hex});
    const owned_closure = if (closure) |value| try self.allocator.dupe(u8, value) else null;
    try self.files.append(self.allocator, .{
        .descriptor = .{
            .path = try self.allocator.dupe(u8, path),
            .content_id = digest,
            .byte_length = content.len,
            .definition_closure = owned_closure,
        },
        .content = try self.allocator.dupe(u8, content),
    });
    const index = self.files.items.len - 1;
    try self.by_path.put(self.files.items[index].descriptor.path, index);
    self.payload_bytes += content.len;
}

const test_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const test_other_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const test_observation: storage_sources.Observation = .{
    .observation_id = "original-a",
    .evidence_locator = "/explicit/registration.json",
    .evidence_digest = test_digest,
    .evidence_pointer = "/sources/0",
    .binding = .{ .root_pointer = "" },
};
const test_files = [_]File{
    .{ .path = "owner/a.json", .content_id = test_digest, .byte_length = 1 },
    .{ .path = "owner/b.json", .content_id = test_other_digest, .byte_length = 2 },
};
const test_limits: Limits = .{ .payload_bytes = 3, .manifest_bytes = 64 * 1024 };

fn testDescription() Description {
    return .{
        .scope = .declared,
        .definition_id = "example/owner",
        .definition_digest = test_digest,
        .definition_entry_path = "definition.json",
        .parameter_digest = test_digest,
        .target = .{ .store_id = "target", .generation = "before" },
        .observations = &.{test_observation},
        .evidence_subjects = &.{.{
            .observation_id = test_observation.observation_id,
            .subject = .{
                .source_id = "original-source",
                .kind = .@"unmanaged-root",
                .locator = "/original/source",
            },
        }},
        .sources = &.{.{
            .subject = .{
                .source_id = "original-source",
                .kind = .@"unmanaged-root",
                .locator = "/original/source",
            },
            .files = &test_files,
        }},
        .files = &test_files,
    };
}

test "bundle identity normalizes order and repeated transport observations" {
    const allocator = std.testing.allocator;
    const baseline = try encode(allocator, testDescription(), test_limits);
    defer allocator.free(baseline);
    var repetitions: [100]storage_sources.Observation = @splat(test_observation);
    var supplied = testDescription();
    supplied.files = &.{ test_files[1], test_files[0] };
    for (1..repetitions.len + 1) |count| {
        supplied.observations = repetitions[0..count];
        const bytes = try encode(allocator, supplied, test_limits);
        defer allocator.free(bytes);
        try std.testing.expectEqualStrings(baseline, bytes);
    }
    var parsed = try parse(allocator, baseline, test_limits);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.description.observations.len);
    try std.testing.expectEqual(@as(u64, 3), parsed.payload_bytes);
    try std.testing.expectEqualStrings("owner/a.json", parsed.description.files[0].path);
}

test "bundle identity preserves distinct origins and actual target generations" {
    const allocator = std.testing.allocator;
    const baseline = try encode(allocator, testDescription(), test_limits);
    defer allocator.free(baseline);
    var original = try parse(allocator, baseline, test_limits);
    defer original.deinit();
    var other = test_observation;
    other.observation_id = "original-b";
    var supplied = testDescription();
    supplied.observations = &.{ other, test_observation };
    var subjects: [2]EvidenceSubject = @splat(supplied.evidence_subjects[0]);
    subjects[1].observation_id = other.observation_id;
    supplied.evidence_subjects = &subjects;
    const bytes = try encode(allocator, supplied, test_limits);
    defer allocator.free(bytes);
    var distinct = try parse(allocator, bytes, test_limits);
    defer distinct.deinit();
    try std.testing.expectEqual(@as(usize, 2), distinct.description.observations.len);
    try std.testing.expect(!std.mem.eql(u8, original.digest, distinct.digest));
    supplied = testDescription();
    supplied.target.generation = "after";
    const changed = try encode(allocator, supplied, test_limits);
    defer allocator.free(changed);
    var successor = try parse(allocator, changed, test_limits);
    defer successor.deinit();
    try std.testing.expect(!std.mem.eql(u8, original.digest, successor.digest));
    other = test_observation;
    other.evidence_pointer = "/different";
    supplied.observations = &.{ test_observation, other };
    try std.testing.expectError(
        error.ConflictingObservationId,
        encode(allocator, supplied, test_limits),
    );
}

test "bundle writer and reader enforce the same exact bounds" {
    const allocator = std.testing.allocator;
    const bytes = try encode(allocator, testDescription(), test_limits);
    defer allocator.free(bytes);
    var exact = test_limits;
    exact.manifest_bytes = bytes.len;
    exact.files = 2;
    exact.observations = 1;
    const repeated = try encode(allocator, testDescription(), exact);
    defer allocator.free(repeated);
    try std.testing.expectEqualStrings(bytes, repeated);
    exact.manifest_bytes -= 1;
    try std.testing.expectError(error.BundleManifestTooLarge, parse(allocator, bytes, exact));
    try std.testing.expectError(
        error.BundleManifestTooLarge,
        encode(allocator, testDescription(), exact),
    );
    exact = test_limits;
    exact.payload_bytes = 2;
    try std.testing.expectError(error.BundlePayloadTooLarge, parse(allocator, bytes, exact));
    try std.testing.expectError(
        error.BundlePayloadTooLarge,
        encode(allocator, testDescription(), exact),
    );
    exact = test_limits;
    exact.files = 1;
    try std.testing.expectError(error.TooManyBundleFiles, parse(allocator, bytes, exact));
    try std.testing.expectError(
        error.TooManyBundleFiles,
        encode(allocator, testDescription(), exact),
    );
    var duplicate = testDescription();
    duplicate.files = &.{ test_files[0], test_files[0] };
    try std.testing.expectError(
        error.NonCanonicalBundleFiles,
        encode(allocator, duplicate, test_limits),
    );
    var conflict = test_files[1];
    conflict.content_id = test_files[0].content_id;
    duplicate.files = &.{ test_files[0], conflict };
    try std.testing.expectError(
        error.ConflictingBundleContent,
        encode(allocator, duplicate, test_limits),
    );
}

test "bundle byte counts use exact unsigned arithmetic" {
    const allocator = std.testing.allocator;
    var description = testDescription();
    var huge = test_files[0];
    huge.byte_length = std.math.maxInt(u64);
    description.files = &.{huge};
    description.sources = &.{.{
        .subject = description.sources[0].subject,
        .files = description.files,
    }};
    var limits = test_limits;
    limits.payload_bytes = std.math.maxInt(u64);
    const bytes = try encode(allocator, description, limits);
    defer allocator.free(bytes);
    var parsed = try parse(allocator, bytes, limits);
    defer parsed.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), parsed.payload_bytes);
    description.files = &.{ huge, test_files[1] };
    try std.testing.expectError(
        error.BundlePayloadTooLarge,
        encode(allocator, description, limits),
    );
    const overflow = try std.mem.replaceOwned(
        u8,
        allocator,
        bytes,
        "18446744073709551615",
        "18446744073709551616",
    );
    defer allocator.free(overflow);
    try std.testing.expectError(error.ExpectedUnsigned, parse(allocator, overflow, limits));
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    const bytes = encode(allocator, testDescription(), test_limits) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = try parse(allocator, bytes, test_limits);
    defer parsed.deinit();
}

test "bundle manifest allocation failures release owned data" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        allocationProbe,
        .{},
    );
}
