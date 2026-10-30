const std = @import("std");
const definition_core = @import("definition_core");
const json = definition_core.json;

pub const schema = "ledger-storage-sources/v1";
pub const max_sources: usize = 1024;
pub const max_observations: usize = 10_000;
pub const max_manifest_bytes: usize = 8 * 1024 * 1024;

pub const Limits = struct {
    sources: usize = max_sources,
    observations: usize = max_observations,
    manifest_bytes: usize = max_manifest_bytes,

    fn validate(self: Limits) !void {
        if (self.sources > max_sources or self.observations > max_observations or
            self.manifest_bytes > max_manifest_bytes)
        {
            return error.InvalidSourcesLimits;
        }
    }
};

pub const Kind = enum { @"unmanaged-root", @"managed-root", @"preservation-bundle" };

pub const Binding = struct {
    root_pointer: []const u8,
    store_id_pointer: ?[]const u8 = null,
    source_id_pointer: ?[]const u8 = null,

    pub fn eql(left: Binding, right: Binding) bool {
        return std.mem.eql(u8, left.root_pointer, right.root_pointer) and
            optionalStringEqual(left.store_id_pointer, right.store_id_pointer) and
            optionalStringEqual(left.source_id_pointer, right.source_id_pointer);
    }
};

pub const Subject = struct {
    source_id: []const u8,
    kind: Kind,
    locator: []const u8,
    store_id: ?[]const u8 = null,

    pub fn validate(self: Subject) !void {
        if (self.source_id.len == 0) return error.InvalidEvidenceSubject;
        try absoluteLocator(self.locator);
        switch (self.kind) {
            .@"unmanaged-root" => if (self.store_id != null) return error.InvalidEvidenceSubject,
            .@"managed-root" => {
                const id = self.store_id orelse return error.InvalidEvidenceSubject;
                if (id.len == 0 or id.len > 256) return error.InvalidEvidenceSubject;
            },
            .@"preservation-bundle" => return error.InvalidEvidenceSubject,
        }
    }
};

pub fn parseSubject(raw: std.json.Value) !Subject {
    const map = try json.object(raw);
    try json.requireExactKeys(map, &.{ "source_id", "kind", "locator", "store_id" });
    try json.requireFields(map, &.{ "source_id", "kind", "locator" });
    const kind = std.meta.stringToEnum(Kind, try json.requiredString(map, "kind")) orelse
        return error.UnsupportedSourceKind;
    const subject: Subject = .{
        .source_id = try json.requiredString(map, "source_id"),
        .kind = kind,
        .locator = try json.requiredString(map, "locator"),
        .store_id = if (map.get("store_id")) |value| try json.string(value) else null,
    };
    try subject.validate();
    return subject;
}

pub const Observation = struct {
    observation_id: []const u8,
    evidence_locator: []const u8,
    evidence_digest: []const u8,
    evidence_pointer: []const u8,
    binding: Binding,
};

pub const Source = struct {
    source_id: []const u8,
    kind: Kind,
    locator: []const u8,
    store_id: ?[]const u8 = null,
    manifest_digest: ?[]const u8 = null,
    observations: []const Observation,
};

pub const Plan = struct {
    parsed: std.json.Parsed(std.json.Value),
    sources: []const Source,
    observation_count: usize,
    digest: []const u8,

    pub fn deinit(self: *Plan) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

const SeenObservation = struct { source_index: usize, value: Observation };

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Plan {
    return parseWithLimits(allocator, bytes, .{});
}

pub fn parseWithLimits(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !Plan {
    try limits.validate();
    if (bytes.len > limits.manifest_bytes) return error.SourcesManifestTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
    errdefer parsed.deinit();
    const root = try json.object(parsed.value);
    try json.requireExactKeys(root, &.{ "schema", "sources" });
    try json.requireFields(root, &.{ "schema", "sources" });
    if (!std.mem.eql(u8, try json.requiredString(root, "schema"), schema)) {
        return error.UnsupportedSourcesSchema;
    }
    const raw_sources = try json.array(try json.field(root, "sources"));
    if (raw_sources.items.len > limits.sources) return error.TooManySources;
    const arena = parsed.arena.allocator();
    const sources = try arena.alloc(Source, raw_sources.items.len);
    var source_ids: std.StringHashMap(void) = .init(allocator);
    defer source_ids.deinit();
    var observation_ids: std.StringHashMap(SeenObservation) = .init(allocator);
    defer observation_ids.deinit();
    var observation_count: usize = 0;
    for (raw_sources.items, 0..) |raw, index| {
        sources[index] = try parseSource(arena, allocator, raw, limits, &observation_count);
        if ((try source_ids.getOrPut(sources[index].source_id)).found_existing) {
            return error.DuplicateSourceId;
        }
        try checkObservationIds(&observation_ids, sources[index].observations, index);
    }
    const digest = try definition_core.canonical_json.digestValueAlloc(arena, parsed.value);
    return .{
        .parsed = parsed,
        .sources = sources,
        .observation_count = observation_count,
        .digest = digest,
    };
}

fn parseSource(
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    raw: std.json.Value,
    limits: Limits,
    observation_count: *usize,
) !Source {
    const map = try json.object(raw);
    const kind_text = try json.requiredString(map, "kind");
    const kind = std.meta.stringToEnum(Kind, kind_text) orelse return error.UnsupportedSourceKind;
    const keys: []const []const u8 = switch (kind) {
        .@"unmanaged-root" => &.{ "source_id", "kind", "locator", "observations" },
        .@"managed-root" => &.{ "source_id", "kind", "locator", "store_id", "observations" },
        .@"preservation-bundle" => &.{
            "source_id", "kind", "locator", "manifest_digest", "observations",
        },
    };
    try json.requireExactKeys(map, keys);
    try json.requireFields(map, keys);
    const locator = try json.requiredString(map, "locator");
    try absoluteLocator(locator);
    const store_id = if (kind == .@"managed-root")
        try json.requiredString(map, "store_id")
    else
        null;
    const manifest_digest = if (kind == .@"preservation-bundle")
        try json.requiredString(map, "manifest_digest")
    else
        null;
    if (manifest_digest) |digest| try json.digest(digest);
    const raw_observations = try json.array(try json.field(map, "observations"));
    if (raw_observations.items.len > limits.observations - observation_count.*) {
        return error.TooManyObservations;
    }
    observation_count.* += raw_observations.items.len;
    const observations = try arena.alloc(Observation, raw_observations.items.len);
    for (raw_observations.items, observations) |observation, *target| {
        target.* = try parseObservation(scratch, observation);
    }
    return .{
        .source_id = try json.requiredString(map, "source_id"),
        .kind = kind,
        .locator = locator,
        .store_id = store_id,
        .manifest_digest = manifest_digest,
        .observations = observations,
    };
}

pub fn parseObservation(allocator: std.mem.Allocator, raw: std.json.Value) !Observation {
    const map = try json.object(raw);
    const keys = &.{
        "observation_id", "evidence_locator", "evidence_digest", "evidence_pointer", "binding",
    };
    try json.requireExactKeys(map, keys);
    try json.requireFields(map, keys);
    const locator = try json.requiredString(map, "evidence_locator");
    try absoluteLocator(locator);
    const digest = try json.requiredString(map, "evidence_digest");
    try json.digest(digest);
    const pointer = try json.string(try json.field(map, "evidence_pointer"));
    var compiled_pointer = try compilePointer(allocator, pointer);
    defer compiled_pointer.deinit(allocator);
    return .{
        .observation_id = try json.requiredString(map, "observation_id"),
        .evidence_locator = locator,
        .evidence_digest = digest,
        .evidence_pointer = pointer,
        .binding = try parseBinding(allocator, try json.field(map, "binding")),
    };
}

fn parseBinding(allocator: std.mem.Allocator, raw: std.json.Value) !Binding {
    const map = try json.object(raw);
    try json.requireExactKeys(map, &.{ "root_pointer", "store_id_pointer", "source_id_pointer" });
    try json.requireFields(map, &.{"root_pointer"});
    return .{
        .root_pointer = try parsePointer(allocator, try json.field(map, "root_pointer")),
        .store_id_pointer = if (map.get("store_id_pointer")) |value|
            try parsePointer(allocator, value)
        else
            null,
        .source_id_pointer = if (map.get("source_id_pointer")) |value|
            try parsePointer(allocator, value)
        else
            null,
    };
}

fn parsePointer(allocator: std.mem.Allocator, raw: std.json.Value) ![]const u8 {
    const text = try json.string(raw);
    var pointer = try compilePointer(allocator, text);
    defer pointer.deinit(allocator);
    return text;
}

fn compilePointer(
    allocator: std.mem.Allocator,
    text: []const u8,
) !definition_core.json_pointer.Pointer {
    return definition_core.json_pointer.compile(allocator, text) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

pub const EvidenceClaims = struct {
    parsed: std.json.Parsed(std.json.Value),
    locator: []const u8,
    store_id: ?[]const u8,
    source_id: ?[]const u8,

    pub fn deinit(self: *EvidenceClaims) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub fn readObservationClaims(
    allocator: std.mem.Allocator,
    observation: Observation,
    bytes: []const u8,
) !EvidenceClaims {
    var evidence = try readEvidence(allocator, observation, bytes);
    errdefer evidence.parsed.deinit();
    const locator = try claimString(allocator, evidence.selected, observation.binding.root_pointer);
    try absoluteLocator(locator);
    return .{
        .parsed = evidence.parsed,
        .locator = locator,
        .store_id = if (observation.binding.store_id_pointer) |pointer|
            try claimString(allocator, evidence.selected, pointer)
        else
            null,
        .source_id = if (observation.binding.source_id_pointer) |pointer|
            try claimString(allocator, evidence.selected, pointer)
        else
            null,
    };
}

pub fn verifyBoundObservationEvidence(
    allocator: std.mem.Allocator,
    observation: Observation,
    subject: Subject,
    bytes: []const u8,
) !void {
    try subject.validate();
    var claims = try readObservationClaims(allocator, observation, bytes);
    defer claims.deinit();
    if (!std.mem.eql(u8, claims.locator, subject.locator)) {
        return error.SourceEvidenceRootMismatch;
    }
    if (claims.store_id) |id| {
        if (!optionalStringEqual(id, subject.store_id)) {
            return error.SourceEvidenceStoreIdentityMismatch;
        }
    }
    if (claims.source_id) |id| {
        if (!std.mem.eql(u8, id, subject.source_id)) {
            return error.SourceEvidenceSourceIdentityMismatch;
        }
    }
}

fn claimString(
    allocator: std.mem.Allocator,
    selected: std.json.Value,
    text: []const u8,
) ![]const u8 {
    var pointer = try compilePointer(allocator, text);
    defer pointer.deinit(allocator);
    const value = definition_core.json_pointer.lookup(selected, pointer) orelse
        return error.SourceEvidenceClaimMissing;
    return json.string(value);
}

pub fn verifyObservationEvidence(
    allocator: std.mem.Allocator,
    observation: Observation,
    bytes: []const u8,
) !void {
    var evidence = try readEvidence(allocator, observation, bytes);
    defer evidence.parsed.deinit();
}

const Evidence = struct {
    parsed: std.json.Parsed(std.json.Value),
    selected: std.json.Value,
};

fn readEvidence(
    allocator: std.mem.Allocator,
    observation: Observation,
    bytes: []const u8,
) !Evidence {
    if (bytes.len > max_manifest_bytes) return error.SourceEvidenceTooLarge;
    const digest = try definition_core.canonical_json.digestBytesAlloc(allocator, bytes);
    defer allocator.free(digest);
    if (!std.mem.eql(u8, observation.evidence_digest, digest)) {
        return error.SourceEvidenceDigestMismatch;
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
    errdefer parsed.deinit();
    var pointer = try compilePointer(allocator, observation.evidence_pointer);
    defer pointer.deinit(allocator);
    const selected = definition_core.json_pointer.lookup(parsed.value, pointer) orelse
        return error.SourceEvidencePointerMissing;
    return .{ .parsed = parsed, .selected = selected };
}

fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |value| return if (right) |other| std.mem.eql(u8, value, other) else false;
    return right == null;
}

fn checkObservationIds(
    seen: *std.StringHashMap(SeenObservation),
    observations: []const Observation,
    source_index: usize,
) !void {
    for (observations) |observation| {
        const entry = try seen.getOrPut(observation.observation_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .source_index = source_index, .value = observation };
            continue;
        }
        if (entry.value_ptr.source_index == source_index) return error.DuplicateObservationId;
        const previous = entry.value_ptr.value;
        if (!std.mem.eql(u8, previous.evidence_locator, observation.evidence_locator) or
            !std.mem.eql(u8, previous.evidence_digest, observation.evidence_digest) or
            !std.mem.eql(u8, previous.evidence_pointer, observation.evidence_pointer) or
            !previous.binding.eql(observation.binding))
        {
            return error.ConflictingObservationId;
        }
        entry.value_ptr.source_index = source_index;
    }
}

fn absoluteLocator(locator: []const u8) !void {
    if (locator.len == 0 or locator[0] != '/') return error.InvalidSourceLocator;
    if (locator.len == 1) return;
    json.repositoryRelativePath(locator[1..], false) catch return error.InvalidSourceLocator;
}

pub fn encode(
    allocator: std.mem.Allocator,
    sources: []const Source,
    limits: Limits,
) ![]u8 {
    try limits.validate();
    if (sources.len > limits.sources) return error.TooManySources;
    var observation_count: usize = 0;
    for (sources) |source| {
        if (source.observations.len > limits.observations - observation_count) {
            return error.TooManyObservations;
        }
        observation_count += source.observations.len;
    }
    const buffer = try allocator.alloc(u8, limits.manifest_bytes);
    defer allocator.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    std.json.Stringify.value(.{ .schema = schema, .sources = sources }, .{
        .emit_null_optional_fields = false,
    }, &writer) catch return error.SourcesManifestTooLarge;
    var plan = try parseWithLimits(allocator, writer.buffered(), limits);
    defer plan.deinit();
    const canonical = try definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        plan.parsed.value,
    );
    errdefer allocator.free(canonical);
    if (canonical.len > limits.manifest_bytes) return error.SourcesManifestTooLarge;
    return canonical;
}

const test_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const fixture =
    \\{"schema":"ledger-storage-sources/v1","sources":[{
    \\"source_id":"source-a","kind":"managed-root","locator":"/explicit/store",
    \\"store_id":"store-a","observations":[{"observation_id":"origin-a",
    \\"evidence_locator":"/explicit/registration.json",
    \\"evidence_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    \\"evidence_pointer":"","binding":{"root_pointer":"/store_root"}}]}]}
;

fn expectRejected(before: []const u8, after: []const u8, expected: anyerror) !void {
    const bytes = try std.mem.replaceOwned(u8, std.testing.allocator, fixture, before, after);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(expected, parse(std.testing.allocator, bytes));
}

fn testSource(id: []const u8, observations: []const Observation) Source {
    return .{
        .source_id = id,
        .kind = .@"unmanaged-root",
        .locator = "/explicit/root",
        .observations = observations,
    };
}

const test_observation: Observation = .{
    .observation_id = "original",
    .evidence_locator = "/explicit/manifest.json",
    .evidence_digest = test_digest,
    .evidence_pointer = "/sources/0",
    .binding = .{ .root_pointer = "/root" },
};

test "source evidence validates exact bytes and the declared observation pointer" {
    const allocator = std.testing.allocator;
    const bytes = "{\"sources\":[{\"root\":\"/explicit/root\"}]}";
    const digest = try definition_core.canonical_json.digestBytesAlloc(allocator, bytes);
    defer allocator.free(digest);
    var observation = test_observation;
    observation.evidence_digest = digest;
    try verifyObservationEvidence(allocator, observation, bytes);
    try std.testing.expectError(
        error.SourceEvidenceDigestMismatch,
        verifyObservationEvidence(allocator, observation, "{}"),
    );
    observation.evidence_pointer = "/sources/1";
    try std.testing.expectError(
        error.SourceEvidencePointerMissing,
        verifyObservationEvidence(allocator, observation, bytes),
    );
}

test "storage sources owns input and writer uses reader grammar for every kind" {
    const allocator = std.testing.allocator;
    const owned_input = try allocator.dupe(u8, fixture);
    var plan = try parse(allocator, owned_input);
    allocator.free(owned_input);
    defer plan.deinit();
    try std.testing.expectEqualStrings("store-a", plan.sources[0].store_id.?);
    try std.testing.expectEqual(@as(usize, 1), plan.observation_count);
    const sources = [_]Source{
        plan.sources[0],
        testSource("source-b", &.{test_observation}),
        .{
            .source_id = "source-c",
            .kind = .@"preservation-bundle",
            .locator = "/explicit/bundle",
            .manifest_digest = test_digest,
            .observations = &.{test_observation},
        },
    };
    const encoded = try encode(allocator, &sources, .{});
    defer allocator.free(encoded);
    var reparsed = try parse(allocator, encoded);
    defer reparsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), reparsed.sources.len);
    try std.testing.expectEqual(@as(usize, 3), reparsed.observation_count);
    try std.testing.expectEqualStrings(
        "/sources/0",
        reparsed.sources[2].observations[0].evidence_pointer,
    );
    const repeated = try encode(allocator, reparsed.sources, .{});
    defer allocator.free(repeated);
    try std.testing.expectEqualStrings(encoded, repeated);
}

test "storage sources rejects closed grammar violations and kind field misuse" {
    try expectRejected("\"sources\":", "\"extra\":0,\"sources\":", error.UnknownField);
    try expectRejected("\"source_id\":", "\"extra\":0,\"source_id\":", error.UnknownField);
    try expectRejected(
        "\"observation_id\":",
        "\"extra\":0,\"observation_id\":",
        error.UnknownField,
    );
    try expectRejected("\"store_id\":\"store-a\",", "", error.MissingField);
    try expectRejected(
        "\"source_id\":",
        "\"source_id\":\"other\",\"source_id\":",
        error.DuplicateField,
    );
    try expectRejected(
        "\"evidence_pointer\":\"\"",
        "\"evidence_pointer\":null",
        error.ExpectedString,
    );
    try expectRejected("managed-root", "unmanaged-root", error.UnknownField);
    try expectRejected("managed-root", "preservation-bundle", error.UnknownField);
    try expectRejected("managed-root", "unknown", error.UnsupportedSourceKind);
    try expectRejected(
        "ledger-storage-sources/v1",
        "ledger-storage-sources/v2",
        error.UnsupportedSourcesSchema,
    );
    try expectRejected("/explicit/store", "relative", error.InvalidSourceLocator);
    try expectRejected("/explicit/store", "/explicit/../store", error.InvalidSourceLocator);
    try expectRejected("/explicit/store", "/explicit//store", error.InvalidSourceLocator);
    try expectRejected("/explicit/store", "/explicit/store/", error.InvalidSourceLocator);
    try expectRejected("/explicit/store", "/explicit/\\u0000store", error.InvalidSourceLocator);
    try expectRejected(
        "/explicit/registration.json",
        "/./registration",
        error.InvalidSourceLocator,
    );
    try expectRejected(
        "\"evidence_pointer\":\"\"",
        "\"evidence_pointer\":\"/~2\"",
        error.InvalidJsonPointer,
    );
    try expectRejected(test_digest, "sha256:abc", error.InvalidDigest);
    try expectRejected("\"store_id\":\"store-a\"", "\"store_id\":0", error.ExpectedString);
}

test "storage sources requires closed valid binding selectors" {
    try expectRejected(
        ",\"binding\":{\"root_pointer\":\"/store_root\"}",
        "",
        error.MissingField,
    );
    try expectRejected("\"root_pointer\":", "\"extra\":0,\"root_pointer\":", error.UnknownField);
    try expectRejected("\"root_pointer\":\"/store_root\"", "", error.MissingField);
    inline for (.{ "root_pointer", "store_id_pointer", "source_id_pointer" }) |field| {
        const prefix = if (comptime std.mem.eql(u8, field, "root_pointer"))
            ""
        else
            "\"root_pointer\":\"/store_root\",";
        try expectRejected(
            "\"root_pointer\":\"/store_root\"",
            prefix ++ "\"" ++ field ++ "\":null",
            error.ExpectedString,
        );
        try expectRejected(
            "\"root_pointer\":\"/store_root\"",
            prefix ++ "\"" ++ field ++ "\":\"/~2\"",
            error.InvalidJsonPointer,
        );
    }
}

test "storage sources rejects duplicate sources and conflicting observation evidence" {
    const allocator = std.testing.allocator;
    const a = testSource("a", &.{test_observation});
    try std.testing.expectError(error.DuplicateSourceId, encode(allocator, &.{ a, a }, .{}));
    const duplicate = testSource("a", &.{ test_observation, test_observation });
    try std.testing.expectError(
        error.DuplicateObservationId,
        encode(allocator, &.{duplicate}, .{}),
    );
    inline for (.{ "evidence_locator", "evidence_digest", "evidence_pointer" }) |field| {
        var changed = test_observation;
        @field(changed, field) = if (std.mem.eql(u8, field, "evidence_digest"))
            "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        else
            "/different";
        const b = testSource("b", &.{changed});
        try std.testing.expectError(
            error.ConflictingObservationId,
            encode(allocator, &.{ a, b }, .{}),
        );
    }
}

test "storage sources rejects conflicting binding selectors for an observation" {
    const allocator = std.testing.allocator;
    const original = testSource("a", &.{test_observation});
    inline for (.{ "root_pointer", "store_id_pointer", "source_id_pointer" }) |field| {
        var changed = test_observation;
        @field(changed.binding, field) = "/different";
        try std.testing.expectError(error.ConflictingObservationId, encode(
            allocator,
            &.{ original, testSource("b", &.{changed}) },
            .{},
        ));
    }
}

test "storage sources writer rejects missing and forbidden kind identities" {
    const allocator = std.testing.allocator;
    var source = testSource("source", &.{});
    source.kind = .@"managed-root";
    try std.testing.expectError(error.MissingField, encode(allocator, &.{source}, .{}));
    source.kind = .@"preservation-bundle";
    try std.testing.expectError(error.MissingField, encode(allocator, &.{source}, .{}));
    source.manifest_digest = test_digest;
    source.store_id = "store";
    try std.testing.expectError(error.UnknownField, encode(allocator, &.{source}, .{}));
    source.kind = .@"unmanaged-root";
    source.store_id = null;
    try std.testing.expectError(error.UnknownField, encode(allocator, &.{source}, .{}));
}

fn sourceBoundary(allocator: std.mem.Allocator, count: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const sources = try arena.allocator().alloc(Source, count);
    for (sources, 0..) |*source, index| {
        const id = try std.fmt.allocPrint(arena.allocator(), "source-{d}", .{index});
        source.* = testSource(id, &.{});
    }
    if (count > max_sources) {
        const raw = try std.json.Stringify.valueAlloc(allocator, .{
            .schema = schema,
            .sources = sources,
        }, .{ .emit_null_optional_fields = false });
        defer allocator.free(raw);
        try std.testing.expectError(error.TooManySources, parse(allocator, raw));
        try std.testing.expectError(error.TooManySources, encode(allocator, sources, .{}));
        return;
    }
    const encoded = try encode(allocator, sources, .{});
    defer allocator.free(encoded);
    var plan = try parse(allocator, encoded);
    defer plan.deinit();
    try std.testing.expectEqual(count, plan.sources.len);
}

test "storage sources accepts 129 and 1024 sources and rejects 1025" {
    try sourceBoundary(std.testing.allocator, 129);
    try sourceBoundary(std.testing.allocator, max_sources);
    try sourceBoundary(std.testing.allocator, max_sources + 1);
}

test "storage sources bounds original observations before deduplication" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const observations = try arena.allocator().alloc(Observation, max_observations + 1);
    for (observations, 0..) |*observation, index| {
        observation.* = test_observation;
        observation.observation_id = try std.fmt.allocPrint(
            arena.allocator(),
            "original-{d}",
            .{index},
        );
    }
    const source = testSource("source", observations[0..max_observations]);
    const encoded = try encode(allocator, &.{source}, .{});
    defer allocator.free(encoded);
    var plan = try parse(allocator, encoded);
    defer plan.deinit();
    try std.testing.expectEqual(max_observations, plan.observation_count);
    const too_many = [_]Source{testSource("source", observations)};
    const raw = try std.json.Stringify.valueAlloc(allocator, .{
        .schema = schema,
        .sources = &too_many,
    }, .{ .emit_null_optional_fields = false });
    defer allocator.free(raw);
    try std.testing.expectError(error.TooManyObservations, parse(allocator, raw));
    try std.testing.expectError(error.TooManyObservations, encode(
        allocator,
        &.{testSource("source", observations)},
        .{},
    ));
    try std.testing.expectError(error.TooManyObservations, encode(
        allocator,
        &.{ source, testSource("another", observations[0..1]) },
        .{},
    ));
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var plan = try parse(allocator, fixture);
    defer plan.deinit();
    const encoded = try encode(allocator, plan.sources, .{ .manifest_bytes = 4096 });
    defer allocator.free(encoded);
    const at_limit = try encode(allocator, plan.sources, .{ .manifest_bytes = encoded.len });
    defer allocator.free(at_limit);
    try std.testing.expectEqualStrings(encoded, at_limit);
}

test "storage sources reader writer byte bounds and allocation failures agree" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, max_manifest_bytes + 1);
    defer allocator.free(bytes);
    @memset(bytes, ' ');
    @memcpy(bytes[0..fixture.len], fixture);
    var plan = try parse(allocator, bytes[0..max_manifest_bytes]);
    defer plan.deinit();
    try std.testing.expectError(error.SourcesManifestTooLarge, parse(allocator, bytes));
    const encoded = try encode(allocator, plan.sources, .{ .manifest_bytes = 4096 });
    defer allocator.free(encoded);
    try std.testing.expectError(error.SourcesManifestTooLarge, encode(
        allocator,
        plan.sources,
        .{ .manifest_bytes = encoded.len - 1 },
    ));
    try std.testing.expectError(error.TooManySources, parseWithLimits(
        allocator,
        fixture,
        .{ .sources = 0 },
    ));
    try std.testing.expectError(error.TooManyObservations, parseWithLimits(
        allocator,
        fixture,
        .{ .observations = 0 },
    ));
    try std.testing.expectError(error.InvalidSourcesLimits, parseWithLimits(
        allocator,
        fixture,
        .{ .sources = max_sources + 1 },
    ));
    try @import("test_support").checkAllAllocationFailures(allocator, allocationProbe, .{});
}

const registration_evidence =
    \\{"record":{"schema":"ledger-repository-registration/v1","store_id":"store-a",
    \\"store_root":"/explicit/root","source_id":"source-a"}}
;

const registration_binding: Binding = .{
    .root_pointer = "/store_root",
    .store_id_pointer = "/store_id",
    .source_id_pointer = "/source_id",
};

const registration_subject: Subject = .{
    .source_id = "source-a",
    .kind = .@"managed-root",
    .locator = "/explicit/root",
    .store_id = "store-a",
};

fn evidenceObservation(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pointer: []const u8,
    binding: Binding,
) !Observation {
    var observation = test_observation;
    observation.evidence_digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        bytes,
    );
    observation.evidence_pointer = pointer;
    observation.binding = binding;
    return observation;
}

test "storage sources binds nested registration and scalar root evidence" {
    const allocator = std.testing.allocator;
    const registration = try evidenceObservation(
        allocator,
        registration_evidence,
        "/record",
        registration_binding,
    );
    defer allocator.free(registration.evidence_digest);
    try verifyBoundObservationEvidence(
        allocator,
        registration,
        registration_subject,
        registration_evidence,
    );
    const bytes = "{\"locator\":\"/explicit/root\",\"source_id\":\"source-a\"}";
    const scalar = try evidenceObservation(allocator, bytes, "/locator", .{ .root_pointer = "" });
    defer allocator.free(scalar.evidence_digest);
    try verifyBoundObservationEvidence(allocator, scalar, .{
        .source_id = "source-a",
        .kind = .@"unmanaged-root",
        .locator = "/explicit/root",
    }, bytes);
    try verifyBoundObservationEvidence(allocator, scalar, registration_subject, bytes);
}

test "storage sources bound evidence rejects unrelated subjects and claims" {
    const allocator = std.testing.allocator;
    var observation = try evidenceObservation(
        allocator,
        registration_evidence,
        "/record",
        registration_binding,
    );
    defer allocator.free(observation.evidence_digest);
    const cases = .{
        .{ "locator", "/unrelated/root", error.SourceEvidenceRootMismatch },
        .{ "store_id", "other-store", error.SourceEvidenceStoreIdentityMismatch },
        .{ "source_id", "other-source", error.SourceEvidenceSourceIdentityMismatch },
    };
    inline for (cases) |case| {
        var subject = registration_subject;
        @field(subject, case[0]) = case[1];
        try std.testing.expectError(case[2], verifyBoundObservationEvidence(
            allocator,
            observation,
            subject,
            registration_evidence,
        ));
    }
    inline for (.{ "root_pointer", "store_id_pointer", "source_id_pointer" }) |field| {
        var changed = observation;
        @field(changed.binding, field) = "/missing";
        try std.testing.expectError(error.SourceEvidenceClaimMissing, readObservationClaims(
            allocator,
            changed,
            registration_evidence,
        ));
        @field(changed.binding, field) = "";
        try std.testing.expectError(error.ExpectedString, readObservationClaims(
            allocator,
            changed,
            registration_evidence,
        ));
    }
    observation.binding.root_pointer = "/schema";
    try std.testing.expectError(error.InvalidSourceLocator, readObservationClaims(
        allocator,
        observation,
        registration_evidence,
    ));
    try verifyObservationEvidence(allocator, observation, registration_evidence);
}

test "storage sources requires valid live subjects" {
    var subject = registration_subject;
    subject.source_id = "";
    try std.testing.expectError(error.InvalidEvidenceSubject, subject.validate());
    subject = registration_subject;
    subject.kind = .@"preservation-bundle";
    try std.testing.expectError(error.InvalidEvidenceSubject, subject.validate());
    subject.kind = .@"unmanaged-root";
    try std.testing.expectError(error.InvalidEvidenceSubject, subject.validate());
    subject = registration_subject;
    subject.store_id = null;
    try std.testing.expectError(error.InvalidEvidenceSubject, subject.validate());
    subject.store_id = "";
    try std.testing.expectError(error.InvalidEvidenceSubject, subject.validate());
    const oversized: [257]u8 = @splat('a');
    subject.store_id = &oversized;
    try std.testing.expectError(error.InvalidEvidenceSubject, subject.validate());
}

fn evidenceClaimsAllocationProbe(allocator: std.mem.Allocator) !void {
    const observation = try evidenceObservation(
        allocator,
        registration_evidence,
        "/record",
        registration_binding,
    );
    defer allocator.free(observation.evidence_digest);
    const bytes = try allocator.dupe(u8, registration_evidence);
    var claims = readObservationClaims(allocator, observation, bytes) catch |err| {
        allocator.free(bytes);
        return err;
    };
    allocator.free(bytes);
    defer claims.deinit();
    try std.testing.expectEqualStrings("/explicit/root", claims.locator);
    try std.testing.expectEqualStrings("store-a", claims.store_id.?);
    try std.testing.expectEqualStrings("source-a", claims.source_id.?);
}

test "storage sources evidence owns claims and bounds parser allocation" {
    const allocator = std.testing.allocator;
    try @import("test_support").checkAllAllocationFailures(
        allocator,
        evidenceClaimsAllocationProbe,
        .{},
    );
    const bytes = try allocator.alloc(u8, max_manifest_bytes + 1);
    defer allocator.free(bytes);
    @memset(bytes, ' ');
    const observation = try evidenceObservation(allocator, bytes, "", .{ .root_pointer = "" });
    defer allocator.free(observation.evidence_digest);
    try std.testing.expectError(error.SourceEvidenceTooLarge, readObservationClaims(
        allocator,
        observation,
        bytes,
    ));
    try std.testing.expectError(error.SourceEvidenceTooLarge, verifyObservationEvidence(
        allocator,
        observation,
        bytes,
    ));
}

test "storage sources parses closed live subjects for retained evidence" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ "{\"source_id\":\"a\",\"kind\":\"unmanaged-root\",\"locator\":\"/root\"}", null },
        .{
            "{\"source_id\":\"a\",\"kind\":\"managed-root\"," ++
                "\"locator\":\"/root\",\"store_id\":\"s\"}",
            null,
        },
        .{
            "{\"source_id\":\"a\",\"kind\":\"managed-root\",\"locator\":\"/root\"}",
            error.InvalidEvidenceSubject,
        },
        .{
            "{\"source_id\":\"a\",\"kind\":\"unmanaged-root\"," ++
                "\"locator\":\"/root\",\"store_id\":\"s\"}",
            error.InvalidEvidenceSubject,
        },
        .{
            "{\"source_id\":\"a\",\"kind\":\"preservation-bundle\",\"locator\":\"/root\"}",
            error.InvalidEvidenceSubject,
        },
        .{
            "{\"source_id\":\"a\",\"kind\":\"unmanaged-root\",\"locator\":\"relative\"}",
            error.InvalidSourceLocator,
        },
        .{
            "{\"source_id\":\"a\",\"kind\":\"unmanaged-root\",\"locator\":\"/root\",\"extra\":0}",
            error.UnknownField,
        },
    };
    inline for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, case[0], .{});
        defer parsed.deinit();
        const expected_error: ?anyerror = case[1];
        if (expected_error) |expected| {
            try std.testing.expectError(expected, parseSubject(parsed.value));
        } else {
            const subject = try parseSubject(parsed.value);
            try std.testing.expectEqualStrings("a", subject.source_id);
            try std.testing.expectEqualStrings("/root", subject.locator);
        }
    }
}
