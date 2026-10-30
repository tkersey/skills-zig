const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const storage_root = @import("storage_root");

pub const definition = @import("definition.zig");
pub const compiled_plan = @import("compiled_plan.zig");
pub const revision_archive = @import("revision_archive.zig");
pub const validation = @import("validation.zig");
pub const materialization = @import("materialization.zig");
pub const document = @import("document.zig");
pub const storage = @import("storage.zig");
pub const definition_archive = @import("definition_archive.zig");
pub const custody = @import("custody.zig");
pub const transaction = @import("transaction.zig");
pub const projection = @import("projection.zig");
pub const replay = @import("replay.zig");
pub const protocol = @import("protocol.zig");
pub const reducer = @import("reducer.zig");
pub const relation = @import("relation.zig");
pub const state_reducer = @import("state_reducer.zig");
pub const segmented_event_log = @import("segmented_event_log.zig");
pub const doctor = @import("doctor.zig");
pub const migration = @import("migration.zig");
pub const envelope = @import("envelope.zig");
pub const checkpoint = @import("checkpoint.zig");
pub const storage_capture = @import("storage_capture.zig");
pub const storage_policy = @import("storage_policy.zig");
pub const storage_preparation = @import("storage_preparation.zig");
pub const storage_sources = @import("storage_sources.zig");
pub const storage_source_admission = @import("storage_source_admission.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const storage_bundle = @import("storage_bundle.zig");
pub const storage_admission = @import("storage_admission.zig");
pub const storage_transport = @import("storage_transport.zig");
pub const storage_preparation_sources = @import("storage_preparation_sources.zig");

test {
    _ = definition;
    _ = compiled_plan;
    _ = revision_archive;
    _ = validation;
    _ = materialization;
    _ = document;
    _ = storage;
    _ = definition_archive;
    _ = custody;
    _ = transaction;
    _ = projection;
    _ = replay;
    _ = protocol;
    _ = reducer;
    _ = relation;
    _ = state_reducer;
    _ = segmented_event_log;
    _ = doctor;
    _ = migration;
    _ = envelope;
    _ = checkpoint;
    _ = storage_capture;
    _ = storage_policy;
    _ = storage_preparation;
    _ = storage_sources;
    _ = storage_source_admission;
    _ = lifecycle;
    _ = storage_bundle;
    _ = storage_admission;
    _ = storage_transport;
    _ = storage_preparation_sources;
}

test "segmented custody upgrade exposes distinct legacy tombstones" {
    try std.testing.expect(!std.mem.eql(
        u8,
        segmented_event_log.legacy_event_tombstone,
        segmented_event_log.legacy_binding_tombstone,
    ));
}

const PlainPlans = struct {
    closure: definition_core.closure.Closure,
    artifact: definition.Plan,
    validator: validation.Plan,
    store: storage.Plan,
    protocol: protocol.Plan,
    projection: projection.Plan,
    parameters: definition_core.parameters.Bindings,

    fn deinit(self: *PlainPlans) void {
        self.parameters.deinit(std.testing.allocator);
        self.projection.deinit(std.testing.allocator);
        self.protocol.deinit(std.testing.allocator);
        self.store.deinit(std.testing.allocator);
        self.validator.deinit(std.testing.allocator);
        self.artifact.deinit(std.testing.allocator);
        self.closure.deinit(std.testing.allocator);
        self.* = undefined;
    }
};

fn roundTripPlainProtocol(compiled: *const protocol.Plan) !protocol.Plan {
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer encoder.deinit();
    try protocol.encodeCache(compiled, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var plan = try protocol.decodeCache(std.testing.allocator, &decoder);
    errdefer plan.deinit(std.testing.allocator);
    try decoder.finish();
    return plan;
}

fn compilePlainPlans() !PlainPlans {
    return compilePlainPlansFrom(@embedFile("fixtures/plain-event-definition.json"));
}

fn compileSegmentedPlainPlansFrom(bytes: []const u8) !PlainPlans {
    const allocator = std.testing.allocator;
    const segmented = try std.mem.replaceOwned(
        u8,
        allocator,
        bytes,
        "\"codec\":\"jsonl\",\"max_bytes\":65536",
        "\"codec\":\"jsonl\",\"layout\":\"segmented\",\"max_bytes\":67108864",
    );
    defer allocator.free(segmented);
    const bounded = try std.mem.replaceOwned(
        u8,
        allocator,
        segmented,
        "\"max_store_bytes\":65536",
        "\"max_store_bytes\":67108864",
    );
    defer allocator.free(bounded);
    return compilePlainPlansFrom(bounded);
}

fn compilePlainPlansFrom(bytes: []const u8) !PlainPlans {
    var definition_tmp = std.testing.tmpDir(.{});
    defer definition_tmp.cleanup();
    try definition_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "plain.json",
        .data = bytes,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.io,
        std.testing.allocator,
        &definition_tmp.dir,
        "plain.json",
        .{},
    );
    errdefer closure.deinit(std.testing.allocator);
    var artifact = try definition.compile(
        std.testing.allocator,
        &closure,
        "plain.json",
    );
    errdefer artifact.deinit(std.testing.allocator);
    var validator = try validation.compile(
        std.testing.allocator,
        &artifact,
    );
    errdefer validator.deinit(std.testing.allocator);
    var store = try storage.compile(
        std.testing.allocator,
        &artifact,
    );
    errdefer store.deinit(std.testing.allocator);
    var compiled_protocol = (try protocol.compile(
        std.testing.allocator,
        &artifact,
        &store,
    )).?;
    defer compiled_protocol.deinit(std.testing.allocator);
    var protocol_plan = try roundTripPlainProtocol(&compiled_protocol);
    errdefer protocol_plan.deinit(std.testing.allocator);
    try protocol.validateCachePlan(
        &protocol_plan,
        &artifact,
        &store,
    );
    try std.testing.expectEqual(protocol.Mode.plain, protocol_plan.mode);
    try std.testing.expect(protocol_plan.reducer_plan != null);
    try std.testing.expect(protocol_plan.state_reducer_plan == null);
    var projection_plan = try projection.compile(
        std.testing.allocator,
        &artifact,
        &store,
        &protocol_plan,
    );
    errdefer projection_plan.deinit(std.testing.allocator);
    var parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &artifact.parameter_declarations,
        &.{},
    );
    errdefer parameters.deinit(std.testing.allocator);
    return .{
        .closure = closure,
        .artifact = artifact,
        .validator = validator,
        .store = store,
        .protocol = protocol_plan,
        .projection = projection_plan,
        .parameters = parameters,
    };
}

fn bindPlainStore(
    scope: *storage_root.Scope,
    plans: *const PlainPlans,
    repo_root: []const u8,
) !void {
    var binding = try transaction.transact(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.closure,
        "plain.json",
        &plans.validator,
        &plans.store,
        &plans.protocol,
        "bind-existing",
        repo_root,
        &.{},
        &plans.parameters,
    );
    defer binding.deinit(std.testing.allocator);
    try std.testing.expect(binding.storage_mutated);
}

fn appendPlainEvent(
    scope: *storage_root.Scope,
    plans: *const PlainPlans,
    repo_root: []const u8,
) !void {
    var appended = try transaction.transact(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.closure,
        "plain.json",
        &plans.validator,
        &plans.store,
        &plans.protocol,
        "append",
        repo_root,
        &.{.{
            .name = "event",
            .bytes = "{\"kind\":\"updated\",\"value\":{\"id\":\"item-1\",\"revision\":1}}",
        }},
        &plans.parameters,
    );
    defer appended.deinit(std.testing.allocator);
    try std.testing.expect(appended.storage_mutated);
}

fn appendPlainCreatedEvent(
    scope: *storage_root.Scope,
    plans: *const PlainPlans,
    repo_root: []const u8,
) !void {
    var appended = try transaction.transact(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.closure,
        "plain.json",
        &plans.validator,
        &plans.store,
        &plans.protocol,
        "append",
        repo_root,
        &.{.{
            .name = "event",
            .bytes = "{\"kind\":\"created\",\"value\":{" ++
                "\"id\":\"item-1\",\"revision\":1}}",
        }},
        &plans.parameters,
    );
    defer appended.deinit(std.testing.allocator);
    try std.testing.expect(appended.storage_mutated);
}

fn appendPlainCreatedEventFor(
    scope: *storage_root.Scope,
    plans: *const PlainPlans,
    repo_root: []const u8,
    id: []const u8,
) !void {
    const bytes = try std.testing.allocator.print(
        "{{\"kind\":\"created\",\"value\":{{" ++
            "\"id\":\"{s}\",\"revision\":1}}}}",
        .{id},
    );
    defer std.testing.allocator.free(bytes);
    try appendPlainRawEvent(scope, plans, repo_root, bytes);
}

fn appendPlainRawEvent(
    scope: *storage_root.Scope,
    plans: *const PlainPlans,
    repo_root: []const u8,
    bytes: []const u8,
) !void {
    var appended = try transaction.transact(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.closure,
        "plain.json",
        &plans.validator,
        &plans.store,
        &plans.protocol,
        "append",
        repo_root,
        &.{.{ .name = "event", .bytes = bytes }},
        &plans.parameters,
    );
    defer appended.deinit(std.testing.allocator);
    try std.testing.expect(appended.storage_mutated);
}

const expected_plain_projection: storage_admission.ExpectedProjection = .{
    .name = "current",
    .payload = "[{\"current\":{\"id\":\"item-1\",\"revision\":1}," ++
        "\"event_count\":2,\"id\":\"item-1\",\"status\":\"current\"}]",
    .exit_code = 0,
};

fn expectPlainProjection(
    scope: *storage_root.Scope,
    plans: *const PlainPlans,
    repo_root: []const u8,
) !void {
    var result = try projection.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        &plans.projection,
        "current",
        repo_root,
        &plans.parameters,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        expected_plain_projection.payload,
        result.payload,
    );
}

test "plain protocol binds appends replays and folds without rewriting history" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    try repo_tmp.dir.createDirPath(std.testing.io, ".ledger/example");
    const original =
        "{\"kind\":\"created\",\"value\":{\"id\":\"item-1\",\"revision\":1}}\n";
    try repo_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".ledger/example/plain.jsonl",
        .data = original,
    });
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    try bindPlainStore(scope, &plans, repo_root);
    const after_binding = try repo_tmp.dir.readFileAlloc(
        std.testing.io,
        ".ledger/example/plain.jsonl",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(after_binding);
    try std.testing.expectEqualStrings(original, after_binding);
    try appendPlainEvent(scope, &plans, repo_root);
    try expectPlainProjection(scope, &plans, repo_root);
}

test "segmented sorted fold preserves source order through checkpoint and append" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    try appendPlainCreatedEventFor(scope, &plans, repo_root, "z");
    try appendPlainCreatedEvent(scope, &plans, repo_root);
    try expectOrderedPlainId(scope, &plans, repo_root, "first", "z");
    try expectOrderedPlainId(scope, &plans, repo_root, "last", "item-1");
    var segmented = try compileSegmentedPlainPlansFrom(
        @embedFile("fixtures/plain-event-definition.json"),
    );
    defer segmented.deinit();
    var migrated = try migration.execute(
        scope,
        std.testing.allocator,
        &segmented.artifact,
        &segmented.closure,
        "plain.json",
        &segmented.store,
        &segmented.protocol,
        repo_root,
        &segmented.parameters,
    );
    defer migrated.deinit(std.testing.allocator);
    try expectOrderedPlainId(scope, &segmented, repo_root, "first", "z");
    try expectOrderedPlainId(scope, &segmented, repo_root, "last", "item-1");
    try appendPlainEvent(scope, &segmented, repo_root);
    try appendPlainCreatedEventFor(scope, &segmented, repo_root, "a");
    try expectOrderedPlainId(scope, &segmented, repo_root, "first", "z");
    try expectOrderedPlainId(scope, &segmented, repo_root, "last", "a");
}

test "ordered fold follows archived selectors on admitted plain and segmented plans" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    try expectArchivedSelectors(scope, false);
    try expectArchivedSelectors(scope, true);
}

fn archivedSelectorDefinition(with_history: bool) ![]u8 {
    const allocator = std.testing.allocator;
    var bytes = try allocator.dupe(u8, @embedFile("fixtures/plain-event-definition.json"));
    errdefer allocator.free(bytes);
    const replacements = [_][2][]const u8{
        .{ "/value/id", "/value/next_id" },
        .{ "\"id\":{}", "\"next_id\":{}" },
        .{ "/kind", "/event" },
        .{ "\"kind\":{}", "\"event\":{}" },
    };
    for (replacements) |pair| {
        const next = try std.mem.replaceOwned(u8, allocator, bytes, pair[0], pair[1]);
        allocator.free(bytes);
        bytes = next;
    }
    if (with_history) {
        const next = try std.mem.replaceOwned(
            u8,
            allocator,
            bytes,
            "\"key_field\":\"id\",\"state_field\":\"status\"",
            "\"key_field\":\"id\",\"state_field\":\"status\"," ++
                "\"event_kind_counts\":[{\"kind\":\"created\",\"field\":\"created_count\"}]",
        );
        allocator.free(bytes);
        bytes = next;
    }
    return bytes;
}

fn expectArchivedSelectors(scope: *storage_root.Scope, with_history: bool) !void {
    const allocator = std.testing.allocator;
    var old = try compilePlainPlans();
    defer old.deinit();
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    const repo_root = try repo_tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_root);
    try appendPlainCreatedEventFor(scope, &old, repo_root, "z");

    const bytes = try archivedSelectorDefinition(with_history);
    defer allocator.free(bytes);
    var current = try compilePlainPlansFrom(bytes);
    defer current.deinit();
    try appendPlainRawEvent(scope, &current, repo_root,
        \\{"event":"created","value":{"next_id":"a","revision":1}}
    );
    try expectOrderedPlainId(scope, &current, repo_root, "first", "z");
    try expectOrderedPlainId(scope, &current, repo_root, "last", "a");
    if (with_history) {
        try expectPlainCreatedCount(scope, &current, repo_root, "z");
        try expectPlainCreatedCount(scope, &current, repo_root, "a");
        try std.testing.expectError(
            error.SegmentedProjectionHistoryRequiresFullReplay,
            compileSegmentedPlainPlansFrom(bytes),
        );
        return;
    }
    var segmented = try compileSegmentedPlainPlansFrom(bytes);
    defer segmented.deinit();
    var migrated = try migration.execute(
        scope,
        allocator,
        &segmented.artifact,
        &segmented.closure,
        "plain.json",
        &segmented.store,
        &segmented.protocol,
        repo_root,
        &segmented.parameters,
    );
    defer migrated.deinit(allocator);
    try expectOrderedPlainId(scope, &segmented, repo_root, "first", "z");
    try appendPlainRawEvent(scope, &segmented, repo_root,
        \\{"event":"updated","value":{"next_id":"a","revision":1}}
    );
    try expectOrderedPlainId(scope, &segmented, repo_root, "first", "z");
    try expectOrderedPlainId(scope, &segmented, repo_root, "last", "a");
}

fn expectPlainCreatedCount(
    scope: *storage_root.Scope,
    plans: *const PlainPlans,
    repo_root: []const u8,
    id: []const u8,
) !void {
    var result = try projection.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        &plans.projection,
        "current",
        repo_root,
        &plans.parameters,
    );
    defer result.deinit(std.testing.allocator);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        result.payload,
        .{},
    );
    defer parsed.deinit();
    for (parsed.value.array.items) |row| {
        if (std.mem.eql(u8, row.object.get("id").?.string, id)) {
            try std.testing.expectEqual(@as(i64, 1), row.object.get("created_count").?.integer);
            return;
        }
    }
    return error.ExpectedIdentityMissing;
}

fn expectOrderedPlainId(
    scope: *storage_root.Scope,
    plans: *const PlainPlans,
    repo_root: []const u8,
    name: []const u8,
    id: []const u8,
) !void {
    var result = try projection.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        &plans.projection,
        name,
        repo_root,
        &plans.parameters,
    );
    defer result.deinit(std.testing.allocator);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        result.payload,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try std.testing.expectEqualStrings(id, parsed.value.array.items[0].object.get("id").?.string);
}

test "segmented bind existing bootstraps explicit migration" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    try repo_tmp.dir.createDirPath(std.testing.io, ".ledger/example");
    try repo_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".ledger/example/plain.jsonl",
        .data = "{\"kind\":\"created\",\"value\":{\"id\":\"item-1\",\"revision\":1}}\n",
    });
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    try bindPlainStore(scope, &plans, repo_root);
    var migrated = try migration.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.closure,
        "plain.json",
        &plans.store,
        &plans.protocol,
        repo_root,
        &plans.parameters,
    );
    defer migrated.deinit(std.testing.allocator);
    try std.testing.expect(!migrated.already_migrated);
    try std.testing.expectEqual(@as(usize, 1), migrated.records);
    try appendPlainEvent(scope, &plans, repo_root);
    try expectPlainProjection(scope, &plans, repo_root);
}

test "segmented migration preserves legacy jsonl framing" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    try repo_tmp.dir.createDirPath(std.testing.io, ".ledger/example");
    const legacy =
        "{\"kind\":\"created\",\"value\":{" ++
        "\"id\":\"item-1\",\"revision\":1}}\r\n \t\r\n" ++
        "{\"kind\":\"updated\",\"value\":{" ++
        "\"id\":\"item-1\",\"revision\":1}}";
    try repo_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".ledger/example/plain.jsonl",
        .data = legacy,
    });
    const repo_root =
        try repo_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);
    try bindPlainStore(scope, &plans, repo_root);
    const legacy_revision = try definition_core.canonical_json.digestBytesAlloc(
        std.testing.allocator,
        legacy,
    );
    defer std.testing.allocator.free(legacy_revision);
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    var migrated = try migration.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.closure,
        "plain.json",
        &plans.store,
        &plans.protocol,
        repo_root,
        &plans.parameters,
    );
    defer migrated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(legacy_revision, migrated.revision);
    try std.testing.expectEqual(@as(usize, 2), migrated.records);
    try expectLegacySeparatorPending(scope, repo_root);
    try appendPlainEvent(scope, &plans, repo_root);
    var after_append = try segmented_event_log.Snapshot.load(
        scope,
        std.testing.allocator,
        repo_root,
        "example/plain.jsonl",
    );
    defer after_append.deinit(std.testing.allocator);
    try std.testing.expect(!after_append.head.event_separator_pending);
    try std.testing.expect(after_append.event_bytes.len != 0);
    try std.testing.expectEqual(@as(u8, '\n'), after_append.event_bytes[0]);
    var health = try doctor.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        repo_root,
        &plans.parameters,
    );
    defer health.deinit(std.testing.allocator);
    try std.testing.expect(health.healthy);
}

test "segmented successor bounds checkpoint before enforcement" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    try repo_tmp.dir.createDirPath(std.testing.io, ".ledger/example");
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    try appendPlainCreatedEvent(scope, &plans, repo_root);
    plans.artifact.bounds.max_records = 1;
    try appendPlainEvent(scope, &plans, repo_root);
    var snapshot = try segmented_event_log.Snapshot.load(
        scope,
        std.testing.allocator,
        repo_root,
        "example/plain.jsonl",
    );
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), snapshot.head.event_records);
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot.head.checkpoint_event_records,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        snapshot.head.total_event_records,
    );
    const future_path = try snapshot.paths.eventSegmentAlloc(
        std.testing.allocator,
        snapshot.head.event_index + 1,
    );
    defer std.testing.allocator.free(future_path);
    try scope.fs.directory().writeFile(std.testing.io, .{
        .sub_path = future_path,
        .data = "{}\n",
    });
    try std.testing.expectError(
        error.UnexpectedFutureSegment,
        segmented_event_log.auditHistory(scope, std.testing.allocator, &snapshot),
    );
}

test "segmented checkpoint enforces keyed reducer retained bounds" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    try repo_tmp.dir.createDirPath(std.testing.io, ".ledger/example");
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    try appendPlainCreatedEvent(scope, &plans, repo_root);
    try appendPlainCreatedEventFor(scope, &plans, repo_root, "item-2");
    plans.artifact.bounds.max_records = 2;
    plans.protocol.reducer_plan.?.max_retained_value_bytes = 1;
    plans.protocol.reducer_plan.?.max_retained_total_bytes = 1;
    try std.testing.expectError(
        error.CheckpointBoundsExceeded,
        transaction.transact(
            scope,
            std.testing.allocator,
            &plans.artifact,
            &plans.closure,
            "plain.json",
            &plans.validator,
            &plans.store,
            &plans.protocol,
            "append",
            repo_root,
            &.{.{
                .name = "event",
                .bytes = "{\"kind\":\"updated\",\"value\":{" ++
                    "\"id\":\"item-1\",\"revision\":1}}",
            }},
            &plans.parameters,
        ),
    );
}

test "segmented migration treats max records as a suffix bound" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    try repo_tmp.dir.createDirPath(std.testing.io, ".ledger/example");
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    try appendPlainCreatedEvent(scope, &plans, repo_root);
    try appendPlainEvent(scope, &plans, repo_root);
    plans.artifact.bounds.max_records = 1;
    plans.protocol.max_records = 1;
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    var migrated = try migration.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.closure,
        "plain.json",
        &plans.store,
        &plans.protocol,
        repo_root,
        &plans.parameters,
    );
    defer migrated.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), migrated.records);
}

test "segmented full history admits missing genesis and lifetime states" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    try repo_tmp.dir.createDirPath(std.testing.io, ".ledger/example");
    const repo_root =
        try repo_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    const history_projection = &plans.projection.projections[0];
    const fold = history_projection.fold;
    history_projection.fold = null;
    defer history_projection.fold = fold;
    var missing = try projection.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        &plans.projection,
        "current",
        repo_root,
        &plans.parameters,
    );
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[]", missing.payload);
    try appendPlainCreatedEvent(scope, &plans, repo_root);
    var genesis_doctor = try doctor.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        repo_root,
        &plans.parameters,
    );
    defer genesis_doctor.deinit(std.testing.allocator);
    try std.testing.expect(genesis_doctor.healthy);
    var genesis_projection = try projection.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        &plans.projection,
        "current",
        repo_root,
        &plans.parameters,
    );
    defer genesis_projection.deinit(std.testing.allocator);
    for (0..4) |_| try appendPlainEvent(scope, &plans, repo_root);
    var lifetime_doctor = try doctor.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        repo_root,
        &plans.parameters,
    );
    defer lifetime_doctor.deinit(std.testing.allocator);
    try std.testing.expect(lifetime_doctor.healthy);
}

test "segmented present head requires its checkpoint" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    try repo_tmp.dir.createDirPath(std.testing.io, ".ledger/example");
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    try appendPlainCreatedEvent(scope, &plans, repo_root);
    try removePlainCheckpoint(scope, repo_root);
    try std.testing.expectError(
        error.SegmentedProjectionCheckpointMissing,
        projection.execute(
            scope,
            std.testing.allocator,
            &plans.artifact,
            &plans.store,
            &plans.protocol,
            &plans.projection,
            "current",
            repo_root,
            &plans.parameters,
        ),
    );
    try std.testing.expectError(
        error.SegmentedReplayCheckpointMissing,
        transaction.transact(
            scope,
            std.testing.allocator,
            &plans.artifact,
            &plans.closure,
            "plain.json",
            &plans.validator,
            &plans.store,
            &plans.protocol,
            "append",
            repo_root,
            &.{.{
                .name = "event",
                .bytes = "{\"kind\":\"updated\",\"value\":{" ++
                    "\"id\":\"item-1\",\"revision\":2}}",
            }},
            &plans.parameters,
        ),
    );
}

test "segmented migration preserves bytes revision and replay state" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    try repo_tmp.dir.createDirPath(std.testing.io, ".ledger/example");
    const original =
        "{\"kind\":\"created\",\"value\":{\"id\":\"item-1\",\"revision\":1}}\n";
    try repo_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".ledger/example/plain.jsonl",
        .data = original,
    });
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    try bindPlainStore(scope, &plans, repo_root);
    try appendPlainEvent(scope, &plans, repo_root);
    const legacy_bytes = try repo_tmp.dir.readFileAlloc(
        std.testing.io,
        ".ledger/example/plain.jsonl",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(legacy_bytes);
    const legacy_revision = try definition_core.canonical_json.digestBytesAlloc(
        std.testing.allocator,
        legacy_bytes,
    );
    defer std.testing.allocator.free(legacy_revision);
    const binding_path = try custody.bindingPathAlloc(
        scope,
        std.testing.allocator,
        repo_root,
        "example/plain.jsonl",
    );
    defer std.testing.allocator.free(binding_path);
    const legacy_binding = try durable_store.readRegularFileNoSymlink(
        scope.fs,
        std.testing.allocator,
        binding_path,
        1024 * 1024,
    );
    defer std.testing.allocator.free(legacy_binding);
    try verifyPlainMigration(
        scope,
        &plans,
        repo_root,
        legacy_bytes,
        legacy_revision,
        legacy_binding,
    );
}

test "segmented cross-plan admission rejects unsupported surfaces" {
    var plans = try compilePlainPlans();
    defer plans.deinit();
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    try std.testing.expectError(
        error.SegmentedLayoutRequiresProtocol,
        protocol.validateSegmentedSupport(
            &plans.artifact,
            &plans.store,
            null,
        ),
    );
    try verifySegmentedBindingAdmission(&plans);
    try verifySegmentedAppendAdmission(&plans);
    const original_output_bound = plans.artifact.bounds.max_output_bytes;
    plans.artifact.bounds.max_output_bytes =
        segmented_event_log.event_max_bytes + 1;
    try std.testing.expectError(
        error.SegmentedEventOutputBoundsExceeded,
        protocol.validateSegmentedSupport(
            &plans.artifact,
            &plans.store,
            &plans.protocol,
        ),
    );
    plans.artifact.bounds.max_output_bytes = original_output_bound;
    try verifySegmentedProjectionAdmission(&plans);
    const original_retained =
        plans.protocol.reducer_plan.?.max_retained_total_bytes;
    plans.protocol.reducer_plan.?.max_retained_total_bytes =
        checkpoint.max_checkpoint_bytes;
    try std.testing.expectError(
        error.SegmentedCheckpointCapacityExceeded,
        protocol.validateSegmentedSupport(
            &plans.artifact,
            &plans.store,
            &plans.protocol,
        ),
    );
    plans.protocol.reducer_plan.?.max_retained_total_bytes = original_retained;
}

test "segmented migration recovers pending transactions before custody reads" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    try repo_tmp.dir.createDirPath(
        std.testing.io,
        ".ledger/.transactions/dtx-broken",
    );
    try repo_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".ledger/.transactions/dtx-broken/transaction.json",
        .data = "{}",
    });
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    try std.testing.expectError(
        error.TransactionCorrupt,
        migration.execute(
            scope,
            std.testing.allocator,
            &plans.artifact,
            &plans.closure,
            "plain.json",
            &plans.store,
            &plans.protocol,
            repo_root,
            &plans.parameters,
        ),
    );
}

test "event-log projection treats a missing store as an empty relation" {
    var test_scope = storage_root.Scope.init(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
    );
    const scope = &test_scope;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    var result = try projection.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        &plans.projection,
        "current",
        repo_root,
        &plans.parameters,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[]", result.payload);
}

fn expectLegacySeparatorPending(scope: *storage_root.Scope, repo_root: []const u8) !void {
    var before_append = try segmented_event_log.Snapshot.load(
        scope,
        std.testing.allocator,
        repo_root,
        "example/plain.jsonl",
    );
    try std.testing.expect(before_append.head.event_separator_pending);
    try segmented_event_log.auditHistory(
        scope,
        std.testing.allocator,
        &before_append,
    );
    before_append.deinit(std.testing.allocator);
}

fn removePlainCheckpoint(scope: *storage_root.Scope, repo_root: []const u8) !void {
    var snapshot = try segmented_event_log.Snapshot.load(
        scope,
        std.testing.allocator,
        repo_root,
        "example/plain.jsonl",
    );
    var head = try snapshot.head.clone(std.testing.allocator);
    defer head.deinit(std.testing.allocator);
    head.checkpoint_exists = false;
    head.checkpoint_index = 0;
    head.checkpoint_event_bytes = 0;
    head.checkpoint_event_records = 0;
    head.checkpoint_binding_bytes = 0;
    head.checkpoint_binding_rows = 0;
    const head_bytes = try head.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(head_bytes);
    const manifest_path = try std.testing.allocator.dupe(
        u8,
        snapshot.paths.manifest,
    );
    defer std.testing.allocator.free(manifest_path);
    snapshot.deinit(std.testing.allocator);
    try scope.fs.directory().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data = head_bytes,
    });
}

fn verifyPlainMigration(
    scope: *storage_root.Scope,
    plans: *PlainPlans,
    repo_root: []const u8,
    legacy_bytes: []const u8,
    legacy_revision: []const u8,
    legacy_binding: []const u8,
) !void {
    try verifyMigrationAdmission(scope, plans, repo_root);
    var migrated = try migration.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.closure,
        "plain.json",
        &plans.store,
        &plans.protocol,
        repo_root,
        &plans.parameters,
    );
    defer migrated.deinit(std.testing.allocator);
    try std.testing.expect(!migrated.already_migrated);
    try std.testing.expectEqualStrings(legacy_revision, migrated.revision);
    try std.testing.expectEqual(@as(usize, 2), migrated.records);
    var segmented = try segmented_event_log.Snapshot.load(
        scope,
        std.testing.allocator,
        repo_root,
        "example/plain.jsonl",
    );
    defer segmented.deinit(std.testing.allocator);
    try verifySealedMigrationBytes(scope, &segmented, legacy_bytes, legacy_binding);
    try verifyMigratedProjections(scope, plans, repo_root);
    try corruptMigratedCheckpoint(scope, plans, &segmented);
    try expectMigrationCorruptionPreservesCustody(scope, plans, repo_root, &segmented);
    try verifyMigrationRecovery(scope, plans, repo_root, &segmented, legacy_revision);
}

fn verifySealedMigrationBytes(
    scope: *storage_root.Scope,
    segmented: *const segmented_event_log.Snapshot,
    legacy_bytes: []const u8,
    legacy_binding: []const u8,
) !void {
    try std.testing.expectEqual(@as(u64, 1), segmented.head.event_index);
    try std.testing.expectEqual(@as(u64, 1), segmented.head.binding_index);
    try std.testing.expectEqual(@as(usize, 0), segmented.event_bytes.len);
    try std.testing.expectEqual(@as(usize, 0), segmented.binding_bytes.len);
    const sealed_event_path = try segmented.paths.eventSegmentAlloc(
        std.testing.allocator,
        0,
    );
    defer std.testing.allocator.free(sealed_event_path);
    const sealed_events = try durable_store.readRegularFileNoSymlink(
        scope.fs,
        std.testing.allocator,
        sealed_event_path,
        segmented_event_log.event_segment_bytes,
    );
    defer std.testing.allocator.free(sealed_events);
    try std.testing.expectEqualStrings(legacy_bytes, sealed_events);
    const sealed_binding_path = try segmented.paths.bindingSegmentAlloc(
        std.testing.allocator,
        0,
    );
    defer std.testing.allocator.free(sealed_binding_path);
    const sealed_bindings = try durable_store.readRegularFileNoSymlink(
        scope.fs,
        std.testing.allocator,
        sealed_binding_path,
        segmented_event_log.binding_segment_bytes,
    );
    defer std.testing.allocator.free(sealed_bindings);
    try std.testing.expectEqualStrings(legacy_binding, sealed_bindings);
}

fn verifyMigratedProjections(
    scope: *storage_root.Scope,
    plans: *PlainPlans,
    repo_root: []const u8,
) !void {
    try expectPlainProjection(scope, plans, repo_root);
    const post_migration_projection = &plans.projection.projections[0];
    const post_migration_fold = post_migration_projection.fold;
    post_migration_projection.fold = null;
    var raw_projection = try projection.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        &plans.projection,
        "current",
        repo_root,
        &plans.parameters,
    );
    defer raw_projection.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "[{\"kind\":\"created\",\"value\":{" ++
            "\"id\":\"item-1\",\"revision\":1}},{" ++
            "\"kind\":\"updated\",\"value\":{" ++
            "\"id\":\"item-1\",\"revision\":1}}]",
        raw_projection.payload,
    );
    post_migration_projection.fold = post_migration_fold;
    var post_migration_doctor = try doctor.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        repo_root,
        &plans.parameters,
    );
    defer post_migration_doctor.deinit(std.testing.allocator);
    try std.testing.expect(post_migration_doctor.healthy);
}

fn corruptMigratedCheckpoint(
    scope: *storage_root.Scope,
    plans: *const PlainPlans,
    segmented: *const segmented_event_log.Snapshot,
) !void {
    var decoded = try protocol.decodeCheckpoint(
        std.testing.allocator,
        &plans.protocol,
        segmented.checkpoint_bytes,
    );
    defer decoded.deinit(std.testing.allocator);
    decoded.state.next_sequence += 1;
    const invalid_checkpoint = try protocol.encodeCheckpointAlloc(
        std.testing.allocator,
        &decoded.state,
        decoded.definition_digest,
    );
    defer std.testing.allocator.free(invalid_checkpoint);
    const invalid_checkpoint_digest =
        try definition_core.canonical_json.digestBytesAlloc(
            std.testing.allocator,
            invalid_checkpoint,
        );
    defer std.testing.allocator.free(invalid_checkpoint_digest);
    var invalid_head = try segmented.head.clone(std.testing.allocator);
    defer invalid_head.deinit(std.testing.allocator);
    @memcpy(&invalid_head.checkpoint_digest, invalid_checkpoint_digest);
    const invalid_head_bytes = try invalid_head.encodeAlloc(
        std.testing.allocator,
    );
    defer std.testing.allocator.free(invalid_head_bytes);
    try scope.fs.directory().writeFile(std.testing.io, .{
        .sub_path = segmented.checkpoint_path.?,
        .data = invalid_checkpoint,
    });
    try scope.fs.directory().writeFile(std.testing.io, .{
        .sub_path = segmented.paths.manifest,
        .data = invalid_head_bytes,
    });
    try scope.fs.directory().deleteFile(
        std.testing.io,
        segmented.paths.legacy_event,
    );
    try scope.fs.directory().deleteFile(
        std.testing.io,
        segmented.paths.legacy_binding,
    );
}

fn expectMigrationCorruptionPreservesCustody(
    scope: *storage_root.Scope,
    plans: *PlainPlans,
    repo_root: []const u8,
    segmented: *const segmented_event_log.Snapshot,
) !void {
    try std.testing.expectError(
        error.SegmentedCheckpointStateMismatch,
        migration.execute(
            scope,
            std.testing.allocator,
            &plans.artifact,
            &plans.closure,
            "plain.json",
            &plans.store,
            &plans.protocol,
            repo_root,
            &plans.parameters,
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        scope.fs.directory().statFile(
            std.testing.io,
            segmented.paths.legacy_event,
            .{},
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        scope.fs.directory().statFile(
            std.testing.io,
            segmented.paths.legacy_binding,
            .{},
        ),
    );
    try scope.fs.directory().writeFile(std.testing.io, .{
        .sub_path = segmented.paths.legacy_event,
        .data = segmented_event_log.legacy_event_tombstone,
    });
    try scope.fs.directory().writeFile(std.testing.io, .{
        .sub_path = segmented.paths.legacy_binding,
        .data = segmented_event_log.legacy_binding_tombstone,
    });
    const checkpoint_projection = &plans.projection.projections[0];
    const checkpoint_fold = checkpoint_projection.fold;
    checkpoint_projection.fold = null;
    try std.testing.expectError(
        error.SegmentedCheckpointStateMismatch,
        expectPlainProjection(scope, plans, repo_root),
    );
    checkpoint_projection.fold = checkpoint_fold;
}

fn verifyMigrationRecovery(
    scope: *storage_root.Scope,
    plans: *PlainPlans,
    repo_root: []const u8,
    segmented: *const segmented_event_log.Snapshot,
    legacy_revision: []const u8,
) !void {
    try scope.fs.directory().writeFile(std.testing.io, .{
        .sub_path = segmented.checkpoint_path.?,
        .data = segmented.checkpoint_bytes,
    });
    try scope.fs.directory().writeFile(std.testing.io, .{
        .sub_path = segmented.paths.manifest,
        .data = segmented.head_bytes,
    });
    try scope.fs.directory().deleteFile(
        std.testing.io,
        segmented.paths.legacy_event,
    );
    try scope.fs.directory().deleteFile(
        std.testing.io,
        segmented.paths.legacy_binding,
    );
    var reconciled = try migration.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.closure,
        "plain.json",
        &plans.store,
        &plans.protocol,
        repo_root,
        &plans.parameters,
    );
    defer reconciled.deinit(std.testing.allocator);
    try std.testing.expect(!reconciled.already_migrated);
    try verifyMigrationArchiveCustody(scope, plans, repo_root);
    var repeated = try migration.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.closure,
        "plain.json",
        &plans.store,
        &plans.protocol,
        repo_root,
        &plans.parameters,
    );
    defer repeated.deinit(std.testing.allocator);
    try std.testing.expect(repeated.already_migrated);
    try std.testing.expectEqualStrings(legacy_revision, repeated.revision);
    const original_id = plans.artifact.id;
    plans.artifact.id = @constCast("example/wrong-definition");
    defer plans.artifact.id = original_id;
    try std.testing.expectError(
        error.StoreBindingDefinitionMismatch,
        migration.execute(
            scope,
            std.testing.allocator,
            &plans.artifact,
            &plans.closure,
            "plain.json",
            &plans.store,
            &plans.protocol,
            repo_root,
            &plans.parameters,
        ),
    );
}

fn verifyMigrationAdmission(
    scope: *storage_root.Scope,
    plans: *PlainPlans,
    repo_root: []const u8,
) !void {
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    try std.testing.expectError(
        error.SegmentedMigrationRequired,
        projection.execute(
            scope,
            std.testing.allocator,
            &plans.artifact,
            &plans.store,
            &plans.protocol,
            &plans.projection,
            "current",
            repo_root,
            &plans.parameters,
        ),
    );
    var pre_migration_doctor = try doctor.execute(
        scope,
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        repo_root,
        &plans.parameters,
    );
    defer pre_migration_doctor.deinit(std.testing.allocator);
    try std.testing.expect(!pre_migration_doctor.healthy);
    try std.testing.expectEqualStrings(
        "SegmentedMigrationRequired",
        pre_migration_doctor.slots[0].error_code.?,
    );
    const closure_digest = plans.artifact.closure_digest;
    plans.artifact.closure_digest[70] = if (closure_digest[70] == '0')
        '1'
    else
        '0';
    try std.testing.expectError(
        error.DefinitionClosureDigestMismatch,
        migration.execute(
            scope,
            std.testing.allocator,
            &plans.artifact,
            &plans.closure,
            "plain.json",
            &plans.store,
            &plans.protocol,
            repo_root,
            &plans.parameters,
        ),
    );
    plans.artifact.closure_digest = closure_digest;
}

fn verifyMigrationArchiveCustody(
    scope: *storage_root.Scope,
    plans: *PlainPlans,
    repo_root: []const u8,
) !void {
    const archive_path = try definition_archive.pathAlloc(
        scope,
        std.testing.allocator,
        repo_root,
        &plans.artifact.closure_digest,
    );
    defer std.testing.allocator.free(archive_path);
    const archive_bytes = try durable_store.readRegularFileNoSymlink(
        scope.fs,
        std.testing.allocator,
        archive_path,
        definition_archive.max_bytes,
    );
    defer std.testing.allocator.free(archive_bytes);
    try scope.fs.directory().deleteFile(std.testing.io, archive_path);
    const history_projection = &plans.projection.projections[0];
    const fold = history_projection.fold;
    history_projection.fold = null;
    defer history_projection.fold = fold;
    try std.testing.expectError(
        error.HistoricalDefinitionMissing,
        expectPlainProjection(scope, plans, repo_root),
    );
    history_projection.fold = fold;
    try scope.fs.directory().writeFile(std.testing.io, .{
        .sub_path = archive_path,
        .data = archive_bytes,
    });
}

fn verifySegmentedBindingAdmission(plans: *PlainPlans) !void {
    const binding_effect =
        &plans.store.findOperation("bind-existing").?.effects[0];
    try protocol.validateSegmentedSupport(
        &plans.artifact,
        &plans.store,
        &plans.protocol,
    );
    const original_binding_kind = binding_effect.kind;
    binding_effect.kind = .rebind_existing;
    defer binding_effect.kind = original_binding_kind;
    try std.testing.expectError(
        error.UnsupportedSegmentedEffect,
        protocol.validateSegmentedSupport(
            &plans.artifact,
            &plans.store,
            &plans.protocol,
        ),
    );
    binding_effect.kind = .bind_existing;
    try protocol.validateSegmentedSupport(
        &plans.artifact,
        &plans.store,
        &plans.protocol,
    );
}

fn verifySegmentedAppendAdmission(plans: *PlainPlans) !void {
    const effect = &plans.store.findOperation("append").?.effects[0];
    const original_kind = effect.kind;
    effect.kind = .compare_replace;
    try std.testing.expectError(
        error.UnsupportedSegmentedEffect,
        protocol.validateSegmentedSupport(
            &plans.artifact,
            &plans.store,
            &plans.protocol,
        ),
    );
    effect.kind = original_kind;
    effect.idempotency_parameter = try std.testing.allocator.dupe(
        u8,
        "request_id",
    );
    try std.testing.expectError(
        error.UnsupportedSegmentedEffect,
        protocol.validateSegmentedSupport(
            &plans.artifact,
            &plans.store,
            &plans.protocol,
        ),
    );
    std.testing.allocator.free(effect.idempotency_parameter.?);
    effect.idempotency_parameter = null;
}

fn verifySegmentedProjectionAdmission(plans: *PlainPlans) !void {
    const compiled_projection = &plans.projection.projections[0];
    const original_fold = compiled_projection.fold;
    compiled_projection.fold = null;
    try projection.validateCachePlan(
        &plans.projection,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
    );
    const original_source_scope = compiled_projection.source_scope;
    compiled_projection.source_scope = .matching;
    try std.testing.expectError(
        error.SegmentedHistoryProjectionUnsupported,
        projection.validateCachePlan(
            &plans.projection,
            &plans.artifact,
            &plans.store,
            &plans.protocol,
        ),
    );
    compiled_projection.source_scope = original_source_scope;
    compiled_projection.fold = original_fold;
}

const DependencyProbe = struct {
    expected: []const []const u8,
    seen: u64 = 0,

    pub fn visit(self: *@This(), dependency: replay.Dependency) !void {
        switch (dependency) {
            .revision => return error.UnexpectedRevisionDependency,
            .definition_closure => |digest| {
                for (self.expected, 0..) |candidate, index| {
                    if (std.mem.eql(u8, candidate, digest)) {
                        self.seen |= @as(u64, 1) << @intCast(index);
                        return;
                    }
                }
                return error.UnexpectedDefinitionDependency;
            },
        }
    }
};

test "binding dependencies select historical closures without unrelated archives" {
    const allocator = std.testing.allocator;
    var scope = storage_root.Scope.init(durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()));
    var old = try compilePlainPlans();
    defer old.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const repo_root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_root);
    try appendPlainCreatedEventFor(&scope, &old, repo_root, "z");
    const bytes = try archivedSelectorDefinition(false);
    defer allocator.free(bytes);
    var current = try compilePlainPlansFrom(bytes);
    defer current.deinit();
    try appendPlainRawEvent(&scope, &current, repo_root,
        \\{"event":"created","value":{"next_id":"a","revision":1}}
    );
    try temporary.dir.createDirPath(std.testing.io, ".ledger/.revisions");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".ledger/.revisions/unrelated.bin",
        .data = "unrelated opaque payload",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".ledger/.definitions/unrelated.json",
        .data = "not a definition archive",
    });
    var resolved = try storage.resolve(allocator, &current.store, &current.parameters);
    defer resolved.deinit(allocator);
    const slot = resolved.slotSlice()[0];
    var snapshot = try custody.readSlot(&scope, allocator, repo_root, current.artifact.id, slot);
    defer snapshot.deinit(allocator);
    var probe = DependencyProbe{
        .expected = &.{ old.closure.digestSlice(), current.closure.digestSlice() },
    };
    try replay.visitBindingDependencies(
        &scope,
        allocator,
        repo_root,
        current.artifact.id,
        slot,
        snapshot.binding.rows,
        &probe,
    );
    try std.testing.expectEqual(@as(u64, 3), probe.seen);
    const archive_path = try definition_archive.pathAlloc(
        &scope,
        allocator,
        repo_root,
        old.closure.digestSlice(),
    );
    defer allocator.free(archive_path);
    try scope.fs.directory().deleteFile(std.testing.io, archive_path);
    try std.testing.expectError(error.HistoricalDefinitionMissing, replay.visitBindingDependencies(
        &scope,
        allocator,
        repo_root,
        current.artifact.id,
        slot,
        snapshot.binding.rows,
        &probe,
    ));
}

test "segmented dependency enumeration includes sealed history and archived laws" {
    var scope = storage_root.Scope.init(.init(std.testing.io, std.Io.Dir.cwd()));
    const allocator = std.testing.allocator;
    var old = try compilePlainPlans();
    defer old.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    try appendPlainCreatedEvent(&scope, &old, root);
    var plans = try compileSegmentedPlainPlansFrom(
        @embedFile("fixtures/plain-event-definition.json"),
    );
    defer plans.deinit();
    var migrated = try migration.execute(
        &scope,
        allocator,
        &plans.artifact,
        &plans.closure,
        "plain.json",
        &plans.store,
        &plans.protocol,
        root,
        &plans.parameters,
    );
    defer migrated.deinit(allocator);
    try appendPlainEvent(&scope, &plans, root);
    var resolved = try storage.resolve(allocator, &plans.store, &plans.parameters);
    defer resolved.deinit(allocator);
    const slot = resolved.slot(0);
    var pinned = try segmented_event_log.PinnedSnapshot.load(
        &scope,
        allocator,
        root,
        slot.relative_path,
    );
    defer pinned.deinit(allocator);
    var probe = DependencyProbe{
        .expected = &.{ old.closure.digestSlice(), plans.closure.digestSlice() },
    };
    try replay.visitSegmentedBindingDependencies(
        &scope,
        allocator,
        root,
        plans.artifact.id,
        slot,
        &pinned,
        &probe,
    );
    try std.testing.expectEqual(@as(u64, 3), probe.seen);
    var dependencies = segmented_event_log.DependencyIterator{ .pinned = &pinned };
    var count: usize = 0;
    while (try dependencies.next(allocator)) |entry| {
        var dependency = entry;
        defer dependency.deinit(allocator);
        const bytes = try durable_store.readRegularFileNoSymlink(
            scope.fs,
            allocator,
            dependency.path,
            dependency.max_bytes,
        );
        defer allocator.free(bytes);
        try std.testing.expect(bytes.len != 0);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), count);
}

const DeclaredCaptureProbe = struct {
    source: *const storage_root.SourceRoot,
    files: usize = 0,
    captured_bytes: u64 = 0,

    pub fn visit(
        self: *DeclaredCaptureProbe,
        dependency: storage_preparation.FileDependency,
    ) !void {
        const allocator = std.testing.allocator;
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        var scratch: [4096]u8 = undefined;
        const result = try storage_preparation.captureControlFile(
            self.source,
            dependency.path,
            &output.writer,
            dependency.max_bytes,
            &scratch,
        );
        try dependency.validateCaptured(allocator, output.written());
        try std.testing.expectEqual(output.written().len, result.bytes);
        var expected_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(output.written(), &expected_hash, .{});
        try std.testing.expectEqualSlices(u8, &expected_hash, &result.sha256);
        self.files += 1;
        self.captured_bytes += result.bytes;
    }
};

const DeclaredCaptureIo = struct {
    threadlocal var read_bytes: u64 = 0;
    threadlocal var directory_reads: usize = 0;
    threadlocal var allowed_directory: ?durable_store.OpenDirectoryIdentity = null;

    fn read(
        userdata: ?*anyopaque,
        file: std.Io.File,
        buffers: []const []u8,
        offset: u64,
    ) std.Io.File.ReadPositionalError!usize {
        const count = try std.testing.io.vtable.fileReadPositional(userdata, file, buffers, offset);
        read_bytes += count;
        return count;
    }

    fn operate(
        userdata: ?*anyopaque,
        operation: std.Io.Operation,
    ) std.Io.Cancelable!std.Io.Operation.Result {
        const result = try std.testing.io.vtable.operate(userdata, operation);
        switch (result) {
            .file_read_streaming => |value| {
                if (value) |count| read_bytes += count else |_| {}
            },
            else => {},
        }
        return result;
    }

    fn readDirectory(
        userdata: ?*anyopaque,
        reader: *std.Io.Dir.Reader,
        entries: []std.Io.Dir.Entry,
    ) std.Io.Dir.Reader.Error!usize {
        const identity = durable_store.openDirectoryIdentity(std.testing.io, reader.dir) catch
            return error.AccessDenied;
        if (allowed_directory == null or !std.meta.eql(identity, allowed_directory.?)) {
            return error.AccessDenied;
        }
        directory_reads += 1;
        return std.testing.io.vtable.dirRead(userdata, reader, entries);
    }
};

fn captureDeclaredFixture(
    source: *const storage_root.SourceRoot,
    plans: *const PlainPlans,
) !DeclaredCaptureProbe {
    const allocator = std.testing.allocator;
    var selected = try storage_preparation.DeclaredSnapshot.load(
        allocator,
        source,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        1024 * 1024,
    );
    defer selected.deinit(allocator);
    try std.testing.expect(selected.coordinated());
    var probe = DeclaredCaptureProbe{ .source = source };
    try selected.visitFiles(allocator, &probe);
    return probe;
}

test "declared capture reuses native custody and ignores unrelated opaque payload" {
    var scope = storage_root.Scope.init(.init(std.testing.io, std.Io.Dir.cwd()));
    const allocator = std.testing.allocator;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    try appendPlainCreatedEvent(&scope, &plans, root);
    const journal_directory = try tmp.dir.openDir(std.testing.io, ".ledger/.transactions", .{});
    defer journal_directory.close(std.testing.io);
    DeclaredCaptureIo.allowed_directory = try durable_store.openDirectoryIdentity(
        std.testing.io,
        journal_directory,
    );
    defer DeclaredCaptureIo.allowed_directory = null;
    var vtable = std.testing.io.vtable.*;
    vtable.fileReadPositional = DeclaredCaptureIo.read;
    vtable.operate = DeclaredCaptureIo.operate;
    vtable.dirRead = DeclaredCaptureIo.readDirectory;
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var source = try storage_root.SourceRoot.open(allocator, injected, root, null);
    defer source.deinit();
    DeclaredCaptureIo.read_bytes = 0;
    DeclaredCaptureIo.directory_reads = 0;
    const before = try captureDeclaredFixture(&source, &plans);
    const before_reads = DeclaredCaptureIo.read_bytes;
    try std.testing.expect(before_reads >= before.captured_bytes);
    const before_directory_reads = DeclaredCaptureIo.directory_reads;
    try std.testing.expect(before_directory_reads > 0);
    try std.testing.expectEqual(@as(usize, 8), before.files);
    const unrelated = try tmp.dir.createFile(std.testing.io, ".ledger/unrelated", .{});
    defer unrelated.close(std.testing.io);
    try unrelated.setLength(std.testing.io, 3 * 1024 * 1024 * 1024);
    try tmp.dir.symLink(std.testing.io, "unrelated", ".ledger/unrelated-link", .{});
    DeclaredCaptureIo.read_bytes = 0;
    DeclaredCaptureIo.directory_reads = 0;
    const after = try captureDeclaredFixture(&source, &plans);
    try source.revalidate(root);
    try std.testing.expectEqual(before_reads, DeclaredCaptureIo.read_bytes);
    try std.testing.expectEqual(before_directory_reads, DeclaredCaptureIo.directory_reads);
    try std.testing.expectEqual(before.files, after.files);
    try std.testing.expectEqual(before.captured_bytes, after.captured_bytes);
    try std.testing.expect(after.captured_bytes < 1024 * 1024);
}

test "bound preparation selects covering history and preserves established target authority" {
    const allocator = std.testing.allocator;
    var scope = storage_root.Scope.init(.init(std.testing.io, .cwd()));
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var directories: [4]std.testing.TmpDir = undefined;
    var paths: [4][:0]u8 = undefined;
    var sources: [4]storage_root.SourceRoot = undefined;
    var snapshots: [4]storage_preparation.DeclaredSnapshot = undefined;
    var opened: usize = 0;
    var loaded: usize = 0;
    defer {
        for (snapshots[0..loaded]) |*snapshot| snapshot.deinit(allocator);
        for (sources[0..loaded]) |*source| source.deinit();
        for (paths[0..opened]) |path| allocator.free(path);
        for (directories[0..opened]) |*directory| directory.cleanup();
    }
    for (&directories, &paths, &sources, &snapshots, 0..) |
        *directory,
        *path,
        *source,
        *snapshot,
        index,
    | {
        directory.* = std.testing.tmpDir(.{});
        path.* = directory.dir.realPathFileAlloc(std.testing.io, ".", allocator) catch |err| {
            directory.cleanup();
            return err;
        };
        opened += 1;
        if (index == 3) {
            try appendPlainCreatedEventFor(&scope, &plans, path.*, "different");
        } else {
            try appendPlainCreatedEvent(&scope, &plans, path.*);
            if (index == 1) try appendPlainEvent(&scope, &plans, path.*);
        }
        source.* = try storage_root.SourceRoot.open(allocator, std.testing.io, path.*, null);
        snapshot.* = storage_preparation.DeclaredSnapshot.load(
            allocator,
            source,
            &plans.artifact,
            &plans.store,
            &plans.parameters,
            1024 * 1024,
        ) catch |err| {
            source.deinit();
            return err;
        };
        loaded += 1;
    }
    const select = storage_preparation.selectBoundHistory;
    const prefix_sources = &.{ &snapshots[0], &snapshots[1], &snapshots[2] };
    try std.testing.expectEqual(@as(usize, 1), try select(prefix_sources, null));
    try std.testing.expectEqual(@as(usize, 1), try select(prefix_sources, 1));
    try std.testing.expectError(error.PreparationReconciliationRequired, select(prefix_sources, 0));
    const equivalent_sources = &.{ &snapshots[2], &snapshots[0] };
    const reversed_sources = &.{ &snapshots[1], &snapshots[0] };
    try std.testing.expectEqual(@as(usize, 0), try select(equivalent_sources, null));
    try std.testing.expectEqual(@as(usize, 0), try select(reversed_sources, null));
    try std.testing.expectError(error.PreparationReconciliationRequired, select(
        &.{ &snapshots[0], &snapshots[3] },
        null,
    ));
    try std.testing.expectError(error.NoPreparationSources, select(&.{}, null));
    try std.testing.expectError(error.InvalidPreparationTarget, select(prefix_sources, 3));
    try exerciseDeclaredGroup(&plans, &sources, &snapshots);
}

test "declared bundle captures each native dependency once with stable identity" {
    const allocator = std.testing.allocator;
    var scope = storage_root.Scope.init(.init(std.testing.io, .cwd()));
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    var evidence = try BundleObservationFixture.init(root);
    defer evidence.deinit();
    try appendPlainCreatedEvent(&scope, &plans, root);
    try appendPlainEvent(&scope, &plans, root);
    var source = try storage_root.SourceRoot.open(allocator, std.testing.io, root, null);
    defer source.deinit();
    var snapshot = try storage_preparation.DeclaredSnapshot.load(
        allocator,
        &source,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        1024 * 1024,
    );
    defer snapshot.deinit(allocator);
    var admitted = try evidence.admit(&source);
    defer admitted.deinit();
    const options: storage_bundle.DeclaredOptions = .{
        .closure = &plans.closure,
        .entry_path = "plain.json",
        .target = .{ .store_id = "managed-target", .generation = "observed-before" },
        .evidence = &admitted,
        .limits = .{ .payload_bytes = 1024 * 1024, .manifest_bytes = 64 * 1024 },
    };
    var before = try storage_bundle.captureDeclared(allocator, &snapshot, options);
    defer before.deinit();
    try expectForeignCaptureEvidence(&snapshot, options);
    try std.testing.expectEqual(@as(usize, 6), before.files.len);
    for (before.files) |file| {
        const digest = try definition_core.canonical_json.digestBytesAlloc(allocator, file.content);
        defer allocator.free(digest);
        try std.testing.expectEqualStrings(digest, file.descriptor.content_id);
        try std.testing.expectEqual(file.content.len, file.descriptor.byte_length);
    }
    const unrelated = try tmp.dir.createFile(std.testing.io, ".ledger/unrelated", .{});
    defer unrelated.close(std.testing.io);
    try unrelated.setLength(std.testing.io, 3 * 1024 * 1024 * 1024);
    var after = try storage_bundle.captureDeclared(allocator, &snapshot, options);
    defer after.deinit();
    try std.testing.expectEqualStrings(before.identity, after.identity);
    try std.testing.expectEqualStrings(before.manifest, after.manifest);
    try std.testing.expectEqual(before.payload_bytes, after.payload_bytes);
    var limited = options;
    limited.limits.files = 2;
    try std.testing.expectError(error.TooManyBundleFiles, storage_bundle.captureDeclared(
        allocator,
        &snapshot,
        limited,
    ));
    var next = options;
    next.target.generation = "observed-successor";
    var successor = try storage_bundle.captureDeclared(allocator, &snapshot, next);
    defer successor.deinit();
    try exerciseCapturedAdmission(&before, &plans);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, evidence.path);
    try exerciseBundlePublication(&before, &successor, &plans);
    try exerciseBoundRestoration(&before, &plans);
}

test "explicit preparation sources retain live custody and merge verified transport" {
    const allocator = std.testing.allocator;
    var scope = storage_root.Scope.init(.init(std.testing.io, .cwd()));
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    try appendPlainCreatedEvent(&scope, &plans, path);
    var evidence = try BundleObservationFixture.init(path);
    defer evidence.deinit();
    var source = try storage_root.SourceRoot.open(allocator, std.testing.io, path, null);
    defer source.deinit();
    var admitted = try evidence.admit(&source);
    defer admitted.deinit();
    var older = try captureTransportSource(&source, &admitted, &plans);
    defer older.deinit();
    try appendPlainEvent(&scope, &plans, path);
    try exerciseExplicitSources(&admitted, &older, &plans);
    try exerciseReservedSources(&admitted, &older, &plans);
    try exerciseReservedInstallation(&admitted, &plans);
    try exerciseTargetPublicationHandoff(&older, &plans);
    try appendPlainCreatedEventFor(&scope, &plans, path, "after-custody-release");
}

fn exerciseReservedInstallation(
    admitted: *const storage_source_admission.RootAdmission,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    var fixture = try BundleTargetFixture.init();
    defer fixture.deinit();
    const encoded = try storage_sources.encode(allocator, &.{admitted.descriptor()}, .{});
    defer allocator.free(encoded);
    const options: storage_preparation_sources.ReservedOptions = .{
        .sources = explicitSourceOptions(plans),
        .publication = fixture.publicationOptions(),
        .operation_id = "complete-installation-before-capture",
        .action = .install,
    };
    try expectInstallationPeak(&fixture, admitted.descriptor(), plans, options);
    var held = try storage_preparation_sources.Reserved.open(
        allocator,
        std.testing.io,
        encoded,
        &plans.parameters,
        &fixture.target,
        options,
    );
    defer held.deinit();
    try std.testing.expectError(
        error.PreparationActionMismatch,
        held.publish(&fixture.target, fixture.publicationOptions()),
    );
    try expectInstallationProjection(&fixture, &held, plans);
    var scope = fixture.target.scope().?;
    try expectPlainProjection(&scope, plans, ".");
    try expectCombinedPublication(&fixture, &held.declared.captured);
    var before = try fixture.budget.inspect(allocator);
    defer before.deinit();
    var repeated = try held.install(&fixture.target, &plans.parameters, .{
        .publication = fixture.publicationOptions(),
        .expected_projection = expected_plain_projection,
    });
    defer repeated.deinit(allocator);
    try std.testing.expectEqual(.committed, repeated.receipt.semantic);
    try std.testing.expect(repeated.receipt.reused);
    try std.testing.expectEqual(null, repeated.verification_error);
    var after = try fixture.budget.inspect(allocator);
    defer after.deinit();
    try std.testing.expectEqual(before.used, after.used);
    try std.testing.expectEqual(before.parsed.value.generation, after.parsed.value.generation);
}

test "restartable preparation reuses original evidence across aborted and committed attempts" {
    var plans = try compilePlainPlans();
    defer plans.deinit();
    try exerciseRestartedInstallation(&plans, false);
    try exerciseRestartedInstallation(&plans, true);
}

fn exerciseRestartedInstallation(plans: *const PlainPlans, committed_fault: bool) !void {
    const allocator = std.testing.allocator;
    var fixture = try BundleTargetFixture.init();
    defer fixture.deinit();
    var scope = fixture.target.scope().?;
    try appendPlainCreatedEvent(&scope, plans, ".");
    var evidence = try BundleObservationFixture.init(fixture.path);
    defer evidence.deinit();
    const encoded = encoded: {
        var admitted = try evidence.admit(&fixture.target);
        defer admitted.deinit();
        var alias = admitted.descriptor();
        alias.source_id = "reopened-alias";
        break :encoded try storage_sources.encode(
            allocator,
            &.{ alias, admitted.descriptor() },
            .{},
        );
    };
    defer allocator.free(encoded);
    var options = explicitSourceOptions(plans);
    const context = budgetPreparationOptions(&fixture).budget.?;
    options.budgets = &.{
        .{ .source_id = "native-source", .context = context },
        .{ .source_id = "reopened-alias", .context = context },
    };
    const payload = try std.mem.replaceOwned(
        u8,
        allocator,
        expected_plain_projection.payload,
        "\"event_count\":2",
        "\"event_count\":1",
    );
    defer allocator.free(payload);
    var expected = expected_plain_projection;
    expected.payload = payload;
    try expectRestartedInvalidProjection(&fixture, plans, encoded, options, expected);
    for (0..3) |_| {
        try interruptRestartedInstallation(&fixture, plans, encoded, options, expected, false);
        try reopenBundleTarget(&fixture);
    }
    if (committed_fault) {
        try interruptRestartedInstallation(&fixture, plans, encoded, options, expected, true);
        try reopenBundleTarget(&fixture);
    }
    var result = try runRestartedInstallation(&fixture, plans, encoded, options, expected);
    defer result.deinit(allocator);
    try std.testing.expectEqual(.committed, result.receipt.semantic);
    try std.testing.expectEqual(null, result.receipt.accounting_error);
    try std.testing.expectEqual(null, result.verification_error);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, evidence.path);
    try expectRestartedInstallationReuse(&fixture, plans, encoded, options, expected, &result);
}

fn expectRestartedInvalidProjection(
    fixture: *BundleTargetFixture,
    plans: *const PlainPlans,
    manifest: []const u8,
    options: storage_preparation_sources.Options,
    expected: storage_admission.ExpectedProjection,
) !void {
    var before = try fixture.budget.inspect(std.testing.allocator);
    defer before.deinit();
    var invalid = expected;
    invalid.name = "missing-projection";
    try std.testing.expectError(error.UnknownProjection, runRestartedInstallation(
        fixture,
        plans,
        manifest,
        options,
        invalid,
    ));
    var after = try fixture.budget.inspect(std.testing.allocator);
    defer after.deinit();
    try std.testing.expectEqual(before.parsed.value.generation, after.parsed.value.generation);
    try std.testing.expectEqual(before.used, after.used);
    try std.testing.expectEqual(@as(usize, 0), after.parsed.value.reservations.len);
}

fn runRestartedInstallation(
    fixture: *BundleTargetFixture,
    plans: *const PlainPlans,
    manifest: []const u8,
    options: storage_preparation_sources.Options,
    expected: storage_admission.ExpectedProjection,
) !storage_bundle.Published {
    return storage_preparation_sources.install(
        std.testing.allocator,
        std.testing.io,
        manifest,
        &plans.parameters,
        &fixture.target,
        .{
            .sources = options,
            .publication = fixture.publicationOptions(),
            .operation_id = "restartable-native-installation",
            .action = .install,
        },
        expected,
    );
}

fn interruptRestartedInstallation(
    fixture: *BundleTargetFixture,
    plans: *const PlainPlans,
    manifest: []const u8,
    options: storage_preparation_sources.Options,
    expected: storage_admission.ExpectedProjection,
    committed: bool,
) !void {
    PublicationStageFault.stage_handle = null;
    PublicationCommitFault.fired = false;
    PublicationCommitFault.armed = false;
    var table = std.testing.io.vtable.*;
    table.dirCreateFile = if (committed)
        PublicationCommitFault.create
    else
        PublicationStageFault.create;
    table.fileSync = if (committed) PublicationCommitFault.sync else PublicationStageFault.sync;
    fixture.target.io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    defer fixture.target.io = std.testing.io;
    var result = try runRestartedInstallation(fixture, plans, manifest, options, expected);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(.recovery_required, result.receipt.semantic);
    try std.testing.expectEqual(error.InputOutput, result.receipt.failure.?);
    if (committed) try std.testing.expect(PublicationCommitFault.fired);
    var pending = try fixture.budget.inspect(std.testing.allocator);
    defer pending.deinit();
    try std.testing.expectEqual(@as(usize, 1), pending.parsed.value.reservations.len);
}

fn expectRestartedInstallationReuse(
    fixture: *BundleTargetFixture,
    plans: *const PlainPlans,
    manifest: []const u8,
    options: storage_preparation_sources.Options,
    expected: storage_admission.ExpectedProjection,
    original: *const storage_bundle.Published,
) !void {
    const allocator = std.testing.allocator;
    var before = try fixture.budget.inspect(allocator);
    defer before.deinit();
    try reopenBundleTarget(fixture);
    var reordered = try storage_sources.parse(allocator, manifest);
    defer reordered.deinit();
    const descriptors = try allocator.dupe(storage_sources.Source, reordered.sources);
    defer allocator.free(descriptors);
    std.mem.reverse(storage_sources.Source, descriptors);
    const encoded = try storage_sources.encode(allocator, descriptors, .{});
    defer allocator.free(encoded);
    var result = try runRestartedInstallation(fixture, plans, encoded, options, expected);
    defer result.deinit(allocator);
    try std.testing.expectEqual(.committed, result.receipt.semantic);
    try std.testing.expect(result.receipt.reused);
    try std.testing.expectEqual(null, result.verification_error);
    try std.testing.expectEqualStrings(
        original.receipt.transaction.transaction_id,
        result.receipt.transaction.transaction_id,
    );
    try expectRestartedContextMismatch(fixture, plans, encoded, options, expected);
    var after = try fixture.budget.inspect(allocator);
    defer after.deinit();
    try std.testing.expectEqual(before.used, after.used);
    try std.testing.expectEqual(before.parsed.value.generation, after.parsed.value.generation);
    try std.testing.expectEqual(@as(usize, 0), after.parsed.value.reservations.len);
    try expectRestartedBundleIntegrity(fixture, plans, encoded, options, expected);
}

fn expectRestartedBundleIntegrity(
    fixture: *BundleTargetFixture,
    plans: *const PlainPlans,
    manifest: []const u8,
    options: storage_preparation_sources.Options,
    expected: storage_admission.ExpectedProjection,
) !void {
    const allocator = std.testing.allocator;
    const directory = ".ledger/.preservation/manifests";
    const names = try durable_store.listSortedRegularFilesNoSymlink(
        .init(std.testing.io, fixture.tmp.dir),
        allocator,
        directory,
        16,
        options.limits.bundle.manifest_bytes,
    );
    defer durable_store.freeStringList(allocator, names);
    var selected: ?[]const u8 = null;
    for (names) |name| {
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        try std.testing.expect(selected == null);
        selected = name;
    }
    try std.testing.expect(selected != null);
    const path = try std.fs.path.join(allocator, &.{ directory, selected.? });
    defer allocator.free(path);
    const bytes = try fixture.tmp.dir.readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(options.limits.bundle.manifest_bytes),
    );
    defer allocator.free(bytes);
    var parsed = try storage_bundle.parse(allocator, bytes, options.limits.bundle);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.description.sources.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.description.observations.len);
    const changed = try std.mem.replaceOwned(
        u8,
        allocator,
        bytes,
        "transport-original",
        "transport-Original",
    );
    defer allocator.free(changed);
    try std.testing.expect(!std.mem.eql(u8, changed, bytes));
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = changed });
    var result = try runRestartedInstallation(fixture, plans, manifest, options, expected);
    defer result.deinit(allocator);
    try std.testing.expectEqual(.committed, result.receipt.semantic);
    try std.testing.expectEqual(error.BundleIdentityMismatch, result.verification_error.?);
}

fn expectRestartedContextMismatch(
    fixture: *BundleTargetFixture,
    plans: *const PlainPlans,
    manifest: []const u8,
    options: storage_preparation_sources.Options,
    expected: storage_admission.ExpectedProjection,
) !void {
    var changed = options;
    changed.established_source_id = "native-source";
    var mismatch = try runRestartedInstallation(fixture, plans, manifest, changed, expected);
    defer mismatch.deinit(std.testing.allocator);
    try std.testing.expectEqual(.committed, mismatch.receipt.semantic);
    try std.testing.expectEqual(error.ReservationIdentityMismatch, mismatch.verification_error.?);
    const generation = try std.testing.allocator.dupe(u8, options.target.generation);
    defer std.testing.allocator.free(generation);
    generation[0] = 'T';
    changed = options;
    changed.target.generation = generation;
    var target_mismatch = try runRestartedInstallation(fixture, plans, manifest, changed, expected);
    defer target_mismatch.deinit(std.testing.allocator);
    try std.testing.expectEqual(.committed, target_mismatch.receipt.semantic);
    try std.testing.expectEqual(
        error.ReservationIdentityMismatch,
        target_mismatch.verification_error.?,
    );
    var wrong = expected;
    wrong.payload = "[]";
    var projection_mismatch = try runRestartedInstallation(
        fixture,
        plans,
        manifest,
        options,
        wrong,
    );
    defer projection_mismatch.deinit(std.testing.allocator);
    try std.testing.expectEqual(.committed, projection_mismatch.receipt.semantic);
    try std.testing.expectEqual(
        error.PreparationProjectionMismatch,
        projection_mismatch.verification_error.?,
    );
    try expectRestartedInvalidVerification(fixture, plans, manifest, options, expected);
}

fn expectRestartedInvalidVerification(
    fixture: *BundleTargetFixture,
    plans: *const PlainPlans,
    manifest: []const u8,
    options: storage_preparation_sources.Options,
    expected: storage_admission.ExpectedProjection,
) !void {
    const oversized = try std.testing.allocator.alloc(
        u8,
        plans.artifact.bounds.max_output_bytes + 1,
    );
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    for ([_]bool{ false, true }) |size| {
        var invalid = expected;
        if (size) invalid.payload = oversized else invalid.name = "missing-projection";
        var result = try runRestartedInstallation(fixture, plans, manifest, options, invalid);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(.committed, result.receipt.semantic);
        try std.testing.expectEqual(
            if (size) error.ProjectionOutputTooLarge else error.UnknownProjection,
            result.verification_error.?,
        );
    }
}

fn reopenBundleTarget(fixture: *BundleTargetFixture) !void {
    var target = try storage_root.SourceRoot.open(
        std.testing.allocator,
        std.testing.io,
        fixture.path,
        "managed-target",
    );
    errdefer target.deinit();
    const budget = try durable_store.ReservationBudget.open(
        .init(std.testing.io, fixture.tmp.dir),
        "budget",
    );
    fixture.target.deinit();
    fixture.budget.deinit();
    fixture.target = target;
    fixture.budget = budget;
}

fn expectInstallationProjection(
    fixture: *BundleTargetFixture,
    held: *storage_preparation_sources.Reserved,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    var expected = expected_plain_projection;
    expected.name = "unknown-projection";
    var before = try fixture.budget.inspect(allocator);
    defer before.deinit();
    try std.testing.expectError(error.UnknownProjection, held.install(
        &fixture.target,
        &plans.parameters,
        .{ .publication = fixture.publicationOptions(), .expected_projection = expected },
    ));
    var unchanged = try fixture.budget.inspect(allocator);
    defer unchanged.deinit();
    try std.testing.expectEqual(before.parsed.value.generation, unchanged.parsed.value.generation);
    expected = expected_plain_projection;
    expected.payload = "[]";
    var first = try held.install(&fixture.target, &plans.parameters, .{
        .publication = fixture.publicationOptions(),
        .expected_projection = expected,
    });
    defer first.deinit(allocator);
    try std.testing.expectEqual(.committed, first.receipt.semantic);
    try std.testing.expectEqual(error.PreparationProjectionMismatch, first.verification_error.?);
    try std.testing.expectEqual(null, first.receipt.accounting_error);
    expected = expected_plain_projection;
    expected.exit_code = 3;
    var wrong_exit = try held.install(&fixture.target, &plans.parameters, .{
        .publication = fixture.publicationOptions(),
        .expected_projection = expected,
    });
    defer wrong_exit.deinit(allocator);
    try std.testing.expectEqual(.committed, wrong_exit.receipt.semantic);
    try std.testing.expect(wrong_exit.receipt.reused);
    try std.testing.expectEqual(
        error.PreparationProjectionMismatch,
        wrong_exit.verification_error.?,
    );
}

fn expectInstallationPeak(
    fixture: *BundleTargetFixture,
    descriptor: storage_sources.Source,
    plans: *const PlainPlans,
    options: storage_preparation_sources.ReservedOptions,
) !void {
    const allocator = std.testing.allocator;
    var missing = descriptor;
    const path = try std.fs.path.join(allocator, &.{ fixture.path, "absent-install-source" });
    defer allocator.free(path);
    missing.locator = path;
    const encoded = try storage_sources.encode(allocator, &.{missing}, .{});
    defer allocator.free(encoded);
    const preservation = try durable_store.ReservationBudget.transactionCharge(
        options.publication.limits.payload_bytes + options.publication.limits.manifest_bytes,
        options.publication.limits.manifest_bytes,
    );
    const installation = try storage_admission.installationCharge(
        allocator,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        options.sources.target,
        options.sources.limits.bundle,
    );
    try std.testing.expect(installation.logical_total > preservation.logical_total);
    var before = try fixture.budget.inspect(allocator);
    defer before.deinit();
    var insufficient = options;
    insufficient.publication.free_space.available_bytes = preservation.logical_total +
        before.control_reserved.logical_total + before.parsed.value.policy.minimum_free_bytes +
        before.parsed.value.policy.recovery_reserve_bytes;
    try std.testing.expectError(
        error.ReservationFreeSpaceInsufficient,
        storage_preparation_sources.Reserved.open(
            allocator,
            std.testing.io,
            encoded,
            &plans.parameters,
            &fixture.target,
            insufficient,
        ),
    );
    var after = try fixture.budget.inspect(allocator);
    defer after.deinit();
    try std.testing.expectEqual(before.parsed.value.generation, after.parsed.value.generation);
    try std.testing.expectEqual(@as(usize, 0), after.parsed.value.reservations.len);
}

fn expectCombinedPublication(
    fixture: *BundleTargetFixture,
    captured: *const storage_bundle.Captured,
) !void {
    const allocator = std.testing.allocator;
    var loaded = try storage_bundle.loadPublished(
        allocator,
        &fixture.target,
        captured.identity,
        fixture.publicationOptions().limits,
    );
    defer loaded.deinit();
    try std.testing.expectEqualStrings(captured.manifest, loaded.manifest);
    var budget = try fixture.budget.inspect(allocator);
    defer budget.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.parsed.value.reservations.len);
    try std.testing.expectEqual(@as(u64, 0), budget.reserved.logical_total);
    var directory = try fixture.budget.root.directory.openDir(
        std.testing.io,
        "reservation-terminal",
        .{ .iterate = true },
    );
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    var terminals: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".json")) terminals += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), terminals);
}

fn exerciseReservedSources(
    admitted: *const storage_source_admission.RootAdmission,
    older: *const storage_bundle.Captured,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    var fixture = try BundleTargetFixture.init();
    defer fixture.deinit();
    var existing = try fixture.publish(older);
    defer existing.deinit(allocator);
    try std.testing.expectEqual(.committed, existing.receipt.semantic);
    const encoded = try storage_sources.encode(allocator, &.{admitted.descriptor()}, .{});
    defer allocator.free(encoded);
    const options: storage_preparation_sources.ReservedOptions = .{
        .sources = explicitSourceOptions(plans),
        .publication = fixture.publicationOptions(),
        .operation_id = "declared-preparation-before-capture",
    };
    try expectReservationBeforeCapture(&fixture, admitted.descriptor(), plans, options);
    var reserved = try storage_preparation_sources.Reserved.open(
        allocator,
        std.testing.io,
        encoded,
        &plans.parameters,
        &fixture.target,
        options,
    );
    defer reserved.deinit();
    try std.testing.expect(reserved.reservation.receipt.reused);
    var before = try fixture.budget.inspect(allocator);
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 1), before.parsed.value.reservations.len);
    var published = try reserved.publish(&fixture.target, fixture.publicationOptions());
    defer published.deinit(allocator);
    try std.testing.expectEqual(.committed, published.receipt.semantic);
    try std.testing.expectEqual(null, published.receipt.accounting_error);
    try std.testing.expectEqual(null, published.verification_error);
    var settled = try fixture.budget.inspect(allocator);
    defer settled.deinit();
    try std.testing.expectEqual(@as(usize, 0), settled.parsed.value.reservations.len);
    try std.testing.expectEqual(@as(u64, 0), settled.reserved.logical_total);
    try expectReservedPublicationRetry(&fixture, &reserved, older);
}

fn expectReservationBeforeCapture(
    fixture: *BundleTargetFixture,
    descriptor: storage_sources.Source,
    plans: *const PlainPlans,
    options: storage_preparation_sources.ReservedOptions,
) !void {
    const allocator = std.testing.allocator;
    var missing = descriptor;
    const path = try std.fs.path.join(allocator, &.{ fixture.path, "absent-source" });
    defer allocator.free(path);
    missing.locator = path;
    const encoded = try storage_sources.encode(allocator, &.{missing}, .{});
    defer allocator.free(encoded);
    var insufficient = options;
    insufficient.publication.free_space.available_bytes = 0;
    try std.testing.expectError(
        error.ReservationFreeSpaceInsufficient,
        storage_preparation_sources.Reserved.open(
            allocator,
            std.testing.io,
            encoded,
            &plans.parameters,
            &fixture.target,
            insufficient,
        ),
    );
    var before = try fixture.budget.inspect(allocator);
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 0), before.parsed.value.reservations.len);
    try std.testing.expectError(
        error.UnsupportedSourcesSchema,
        storage_preparation_sources.Reserved.open(
            allocator,
            std.testing.io,
            "{\"schema\":\"unknown\",\"sources\":[]}",
            &plans.parameters,
            &fixture.target,
            options,
        ),
    );
    for (0..3) |_| {
        try std.testing.expectError(
            error.StorageRootMissing,
            storage_preparation_sources.Reserved.open(
                allocator,
                std.testing.io,
                encoded,
                &plans.parameters,
                &fixture.target,
                options,
            ),
        );
    }
    var after = try fixture.budget.inspect(allocator);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.parsed.value.reservations.len);
    try std.testing.expectEqual(before.parsed.value.generation + 1, after.parsed.value.generation);
    const expected = try durable_store.ReservationBudget.transactionCharge(
        options.publication.limits.payload_bytes + options.publication.limits.manifest_bytes,
        options.publication.limits.manifest_bytes,
    );
    try std.testing.expectEqual(expected, after.reserved);
}

fn expectReservedPublicationRetry(
    fixture: *BundleTargetFixture,
    reserved: *const storage_preparation_sources.Reserved,
    older: *const storage_bundle.Captured,
) !void {
    const allocator = std.testing.allocator;
    var before = try fixture.budget.inspect(allocator);
    defer before.deinit();
    var repeated = try reserved.publish(&fixture.target, fixture.publicationOptions());
    defer repeated.deinit(allocator);
    try std.testing.expectEqual(.committed, repeated.receipt.semantic);
    try std.testing.expect(repeated.receipt.reused);
    try std.testing.expectEqual(null, repeated.verification_error);
    try std.testing.expectError(
        error.ReservationIdentityMismatch,
        storage_bundle.publishReservedCaptured(
            allocator,
            &fixture.target,
            older,
            fixture.publicationOptions(),
            &reserved.reservation,
        ),
    );
    var foreign_options = fixture.publicationOptions();
    foreign_options.budget_id = "foreign-budget";
    try std.testing.expectError(
        error.ReservationIdentityMismatch,
        reserved.publish(&fixture.target, foreign_options),
    );
    var after = try fixture.budget.inspect(allocator);
    defer after.deinit();
    try std.testing.expectEqual(before.parsed.value.generation, after.parsed.value.generation);
    try std.testing.expectEqual(before.used, after.used);
    try std.testing.expectEqual(@as(usize, 0), after.parsed.value.reservations.len);
}

fn exerciseTargetPublicationHandoff(
    original: *const storage_bundle.Captured,
    plans: *const PlainPlans,
) !void {
    try exerciseTargetPublicationMode(original, plans, .manual);
    try exerciseTargetPublicationMode(original, plans, .automatic);
    try exerciseTargetPublicationMode(original, plans, .changed);
    try exerciseTargetPublicationMode(original, plans, .committed_recovery);
}

const TargetPublicationMode = enum { manual, automatic, changed, committed_recovery };

fn exerciseTargetPublicationMode(
    original: *const storage_bundle.Captured,
    plans: *const PlainPlans,
    mode: TargetPublicationMode,
) !void {
    const allocator = std.testing.allocator;
    var fixture = try BundleTargetFixture.init();
    defer fixture.deinit();
    var initial = try fixture.publish(original);
    defer initial.deinit(allocator);
    try std.testing.expectEqual(.committed, initial.receipt.semantic);
    var installed = try storage_admission.applyPublished(
        allocator,
        &fixture.target,
        original.identity,
        &plans.parameters,
        .{ .publication = fixture.publicationOptions() },
    );
    defer installed.deinit(allocator);
    try std.testing.expectEqual(.committed, installed.receipt.semantic);
    var evidence = try BundleObservationFixture.init(fixture.path);
    defer evidence.deinit();
    var admitted = try evidence.admit(&fixture.target);
    defer admitted.deinit();
    var alias = admitted.descriptor();
    alias.source_id = "target-alias";
    const encoded = try storage_sources.encode(allocator, &.{ admitted.descriptor(), alias }, .{});
    defer allocator.free(encoded);
    var options = explicitSourceOptions(plans);
    options.target.generation = "target-handoff";
    const context = budgetPreparationOptions(&fixture).budget.?;
    options.budgets = &.{
        .{ .source_id = admitted.descriptor().source_id, .context = context },
        .{ .source_id = alias.source_id, .context = context },
    };
    if (mode != .manual) return exerciseAutomaticTargetInstallation(
        &fixture,
        plans,
        encoded,
        options,
        mode,
    );
    var reservation = try storage_bundle.Reservation.acquire(
        allocator,
        &fixture.target,
        "target-handoff-before-capture",
        fixture.publicationOptions(),
    );
    defer reservation.deinit();
    var held = try storage_preparation_sources.Declared.open(
        allocator,
        std.testing.io,
        encoded,
        &plans.parameters,
        options,
    );
    defer held.deinit();
    var handoff = try held.releaseTargetForPublication(&fixture.target);
    defer handoff.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), handoff.checks.len);
    try std.testing.expectError(
        error.PreparationSourceUncoordinated,
        held.releaseTargetForPublication(&fixture.target),
    );
    try publishWithTargetCustody(&fixture, &held.captured, &handoff, &reservation, plans);
}

fn exerciseAutomaticTargetInstallation(
    fixture: *BundleTargetFixture,
    plans: *const PlainPlans,
    encoded: []const u8,
    options: storage_preparation_sources.Options,
    mode: TargetPublicationMode,
) !void {
    const allocator = std.testing.allocator;
    var held = try storage_preparation_sources.Reserved.open(
        allocator,
        std.testing.io,
        encoded,
        &plans.parameters,
        &fixture.target,
        .{
            .sources = options,
            .publication = fixture.publicationOptions(),
            .operation_id = "automatic-target-installation",
            .action = .install,
        },
    );
    defer held.deinit();
    const payload = try std.mem.replaceOwned(
        u8,
        allocator,
        expected_plain_projection.payload,
        "\"event_count\":2",
        "\"event_count\":1",
    );
    defer allocator.free(payload);
    var expected = expected_plain_projection;
    expected.payload = payload;
    if (mode == .automatic) try expectInstallationPromotionBusy(fixture, &held, plans, expected);
    for (0..3) |_| {
        try interruptAutomaticInstallation(fixture, &held, plans, expected);
    }
    if (mode == .changed) return rejectChangedInstallation(fixture, &held, plans, expected);
    if (mode == .committed_recovery) {
        try interruptCommittedInstallation(fixture, &held, plans, expected);
        try expectRecoveredProjection(fixture, &held, plans, expected);
    }
    for (0..2) |index| {
        var result = try held.install(&fixture.target, &plans.parameters, .{
            .publication = fixture.publicationOptions(),
            .expected_projection = expected,
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(.committed, result.receipt.semantic);
        try std.testing.expectEqual(null, result.receipt.accounting_error);
        try std.testing.expectEqual(null, result.verification_error);
        if (index > 0) try std.testing.expect(result.receipt.reused);
    }
    try std.testing.expect(held.publication != null);
    try std.testing.expectEqual(@as(usize, 2), held.publication.?.checks.len);
}

fn expectRecoveredProjection(
    fixture: *BundleTargetFixture,
    held: *storage_preparation_sources.Reserved,
    plans: *const PlainPlans,
    expected: storage_admission.ExpectedProjection,
) !void {
    var wrong = expected;
    wrong.payload = "[]";
    var recovered = try held.install(&fixture.target, &plans.parameters, .{
        .publication = fixture.publicationOptions(),
        .expected_projection = wrong,
    });
    defer recovered.deinit(std.testing.allocator);
    try std.testing.expectEqual(.committed, recovered.receipt.semantic);
    try std.testing.expectEqual(null, recovered.receipt.accounting_error);
    try std.testing.expectEqual(
        error.PreparationProjectionMismatch,
        recovered.verification_error.?,
    );
}

fn expectInstallationPromotionBusy(
    fixture: *BundleTargetFixture,
    held: *storage_preparation_sources.Reserved,
    plans: *const PlainPlans,
    expected: storage_admission.ExpectedProjection,
) !void {
    var reader = try storage_preparation.DeclaredSnapshot.loadWithContext(
        std.testing.allocator,
        &fixture.target,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        budgetPreparationOptions(fixture),
    );
    defer reader.deinit(std.testing.allocator);
    try std.testing.expectError(error.LockBusy, held.install(
        &fixture.target,
        &plans.parameters,
        .{ .publication = fixture.publicationOptions(), .expected_projection = expected },
    ));
    try std.testing.expect(held.publication != null);
    try std.testing.expectEqual(null, held.publication.?.custody);
}

fn interruptCommittedInstallation(
    fixture: *BundleTargetFixture,
    held: *storage_preparation_sources.Reserved,
    plans: *const PlainPlans,
    expected: storage_admission.ExpectedProjection,
) !void {
    PublicationCommitFault.fired = false;
    PublicationCommitFault.armed = false;
    PublicationCommitFault.table = std.testing.io.vtable.*;
    PublicationCommitFault.table.dirCreateFile = PublicationCommitFault.create;
    PublicationCommitFault.table.fileSync = PublicationCommitFault.sync;
    fixture.target.io = .{
        .userdata = std.testing.io.userdata,
        .vtable = &PublicationCommitFault.table,
    };
    defer fixture.target.io = std.testing.io;
    var interrupted = try held.install(&fixture.target, &plans.parameters, .{
        .publication = fixture.publicationOptions(),
        .expected_projection = expected,
    });
    defer interrupted.deinit(std.testing.allocator);
    try std.testing.expect(PublicationCommitFault.fired);
    try std.testing.expectEqual(.recovery_required, interrupted.receipt.semantic);
    try std.testing.expectEqual(error.InputOutput, interrupted.receipt.failure.?);
    try std.testing.expectEqual(null, held.publication.?.custody);
}

const PublicationCommitFault = struct {
    var fired = false;
    var armed = false;
    var table: std.Io.VTable = undefined;

    fn create(
        userdata: ?*anyopaque,
        directory: std.Io.Dir,
        name: []const u8,
        options: std.Io.Dir.CreateFileOptions,
    ) std.Io.File.OpenError!std.Io.File {
        const file = try std.testing.io.vtable.dirCreateFile(userdata, directory, name, options);
        if (std.mem.eql(u8, std.fs.path.basename(name), "commit.json")) armed = true;
        return file;
    }

    fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        if (armed and !fired) {
            const stat = file.stat(std.testing.io) catch return error.InputOutput;
            if (stat.kind != .directory) return std.testing.io.vtable.fileSync(userdata, file);
            fired = true;
            return error.InputOutput;
        }
        return std.testing.io.vtable.fileSync(userdata, file);
    }
};

fn rejectChangedInstallation(
    fixture: *BundleTargetFixture,
    held: *storage_preparation_sources.Reserved,
    plans: *const PlainPlans,
    expected: storage_admission.ExpectedProjection,
) !void {
    const options: storage_admission.InstallOptions = .{
        .publication = fixture.publicationOptions(),
        .expected_projection = expected,
    };
    const state = try storage_admission.reconcileCaptured(
        std.testing.allocator,
        &fixture.target,
        &held.declared.captured,
        &plans.parameters,
        options,
        &held.reservation,
    );
    try std.testing.expect(state == .ready);
    var scope = fixture.target.scope().?;
    try appendPlainEvent(&scope, plans, ".");
    try std.testing.expectError(error.PreparationSourceChanged, held.install(
        &fixture.target,
        &plans.parameters,
        options,
    ));
    try std.testing.expectEqual(null, held.publication.?.custody);
    try expectPlainProjection(&scope, plans, ".");
    var pending = try fixture.budget.inspect(std.testing.allocator);
    defer pending.deinit();
    try std.testing.expectEqual(@as(usize, 1), pending.parsed.value.reservations.len);
    try std.testing.expectEqual(null, pending.parsed.value.reservations[0].binding);
}

fn interruptAutomaticInstallation(
    fixture: *BundleTargetFixture,
    held: *storage_preparation_sources.Reserved,
    plans: *const PlainPlans,
    expected: storage_admission.ExpectedProjection,
) !void {
    PublicationStageFault.stage_handle = null;
    var table = std.testing.io.vtable.*;
    table.dirCreateFile = PublicationStageFault.create;
    table.fileSync = PublicationStageFault.sync;
    fixture.target.io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    defer fixture.target.io = std.testing.io;
    var interrupted = try held.install(&fixture.target, &plans.parameters, .{
        .publication = fixture.publicationOptions(),
        .expected_projection = expected,
    });
    defer interrupted.deinit(std.testing.allocator);
    try std.testing.expectEqual(.recovery_required, interrupted.receipt.semantic);
    try std.testing.expectEqual(error.InputOutput, interrupted.receipt.failure.?);
    try std.testing.expect(held.publication != null);
    try std.testing.expectEqual(null, held.publication.?.custody);
    var pending = try fixture.budget.inspect(std.testing.allocator);
    defer pending.deinit();
    try std.testing.expectEqual(@as(usize, 1), pending.parsed.value.reservations.len);
    try std.testing.expectEqual(held.reservation.request.charge, pending.reserved);
}

fn publishWithTargetCustody(
    fixture: *BundleTargetFixture,
    captured: *const storage_bundle.Captured,
    handoff: *const storage_preparation.Publication,
    reservation: *const storage_bundle.Reservation,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    var options = fixture.publicationOptions();
    options.preparation = handoff;
    var published = try storage_bundle.publishCaptured(
        allocator,
        &fixture.target,
        captured,
        options,
    );
    defer published.deinit(allocator);
    try std.testing.expectEqual(.committed, published.receipt.semantic);
    try std.testing.expectEqual(null, published.receipt.accounting_error);
    try std.testing.expectEqual(null, published.verification_error);
    for (0..2) |index| {
        var reserved = try storage_bundle.publishReservedCaptured(
            allocator,
            &fixture.target,
            captured,
            options,
            reservation,
        );
        defer reserved.deinit(allocator);
        try std.testing.expectEqual(.committed, reserved.receipt.semantic);
        try std.testing.expectEqual(null, reserved.receipt.accounting_error);
        try std.testing.expectEqual(null, reserved.verification_error);
        if (index > 0) try std.testing.expect(reserved.receipt.reused);
    }
    var applied = try storage_admission.applyPublished(
        allocator,
        &fixture.target,
        captured.identity,
        &plans.parameters,
        .{ .publication = options },
    );
    defer applied.deinit(allocator);
    try std.testing.expectEqual(.committed, applied.receipt.semantic);
    try std.testing.expectEqual(null, applied.receipt.accounting_error);
    try std.testing.expectEqual(null, applied.verification_error);
    var repeated = try storage_admission.applyPublished(
        allocator,
        &fixture.target,
        captured.identity,
        &plans.parameters,
        .{ .publication = options },
    );
    defer repeated.deinit(allocator);
    try std.testing.expectEqual(.committed, repeated.receipt.semantic);
    try std.testing.expect(repeated.receipt.reused);
    try std.testing.expectEqual(null, repeated.verification_error);
}

fn exerciseExplicitSources(
    admitted: *const storage_source_admission.RootAdmission,
    older: *const storage_bundle.Captured,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    var fixture = try BundleTargetFixture.init();
    defer fixture.deinit();
    var publication = try fixture.publish(older);
    defer publication.deinit(allocator);
    try std.testing.expectEqual(.committed, publication.receipt.semantic);
    const transported: storage_sources.Source = .{
        .source_id = "transport-location",
        .kind = .@"preservation-bundle",
        .locator = fixture.path,
        .manifest_digest = older.identity,
        .observations = &.{},
    };
    const descriptor = admitted.descriptor();
    const encoded = try storage_sources.encode(allocator, &.{ descriptor, transported }, .{});
    defer allocator.free(encoded);
    const options = explicitSourceOptions(plans);
    var held = try storage_preparation_sources.Declared.open(
        allocator,
        std.testing.io,
        encoded,
        &plans.parameters,
        options,
    );
    defer held.deinit();
    try held.revalidate();
    try std.testing.expect(held.work.evidence_bytes > 0);
    try std.testing.expect(held.work.snapshot_bytes > 0);
    try std.testing.expect(held.work.captured_bytes > held.captured.payload_bytes);
    var manifest = try storage_bundle.parse(
        allocator,
        held.captured.manifest,
        options.limits.bundle,
    );
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 2), manifest.description.sources.len);
    try std.testing.expectEqual(@as(usize, 1), manifest.description.observations.len);
    var scope = storage_root.Scope.init(.init(std.testing.io, .cwd()));
    try std.testing.expectError(error.LockBusy, appendPlainCreatedEventFor(
        &scope,
        plans,
        descriptor.locator,
        "held-source-write",
    ));
    try expectExplicitSourceSelection(
        encoded,
        &.{ descriptor, transported },
        &held,
        plans,
        options,
    );
    try expectExplicitSourceAlias(&.{ descriptor, transported }, &held, plans, options);
    try expectExplicitBundleDefinition(transported, plans, options);
    try exerciseBoundRestoration(&held.captured, plans);
}

fn explicitSourceOptions(plans: *const PlainPlans) storage_preparation_sources.Options {
    return .{
        .closure = &plans.closure,
        .entry_path = "plain.json",
        .target = .{ .store_id = "managed-target", .generation = "transport-original" },
        .limits = .{
            .bundle = .{ .payload_bytes = 1024 * 1024, .manifest_bytes = 64 * 1024 },
            .evidence_bytes = 1024 * 1024,
            .snapshot_bytes = 4 * 1024 * 1024,
            .capture_bytes = 4 * 1024 * 1024,
        },
    };
}

fn expectExplicitSourceAlias(
    descriptors: []const storage_sources.Source,
    held: *const storage_preparation_sources.Declared,
    plans: *const PlainPlans,
    options: storage_preparation_sources.Options,
) !void {
    const allocator = std.testing.allocator;
    var alias = descriptors[0];
    alias.source_id = "same-root-alias";
    const encoded = try storage_sources.encode(
        allocator,
        &.{ descriptors[0], alias, descriptors[1] },
        .{},
    );
    defer allocator.free(encoded);
    var repeated = try storage_preparation_sources.Declared.open(
        allocator,
        std.testing.io,
        encoded,
        &plans.parameters,
        options,
    );
    defer repeated.deinit();
    var manifest = try storage_bundle.parse(
        allocator,
        repeated.captured.manifest,
        options.limits.bundle,
    );
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 3), manifest.description.sources.len);
    try std.testing.expectEqual(@as(usize, 1), manifest.description.observations.len);
    try std.testing.expectEqual(@as(usize, 2), manifest.description.evidence_subjects.len);
    try std.testing.expectEqual(held.captured.payload_bytes, repeated.captured.payload_bytes);
}

fn expectExplicitBundleDefinition(
    descriptor: storage_sources.Source,
    plans: *const PlainPlans,
    options: storage_preparation_sources.Options,
) !void {
    const allocator = std.testing.allocator;
    const encoded = try storage_sources.encode(allocator, &.{descriptor}, .{});
    defer allocator.free(encoded);
    const different = try std.mem.replaceOwned(
        u8,
        allocator,
        @embedFile("fixtures/plain-event-definition.json"),
        "example/plain-protocol",
        "example/other-protocol",
    );
    defer allocator.free(different);
    var other = try compilePlainPlansFrom(different);
    defer other.deinit();
    var selected = options;
    selected.closure = &other.closure;
    try std.testing.expectError(
        error.PreparationDefinitionMismatch,
        storage_preparation_sources.Declared.open(
            allocator,
            std.testing.io,
            encoded,
            &plans.parameters,
            selected,
        ),
    );
}

test "explicit preparation sources leave an uncoordinated empty root unchanged" {
    const allocator = std.testing.allocator;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    var evidence = try BundleObservationFixture.init(path);
    defer evidence.deinit();
    const encoded = try storage_sources.encode(allocator, &.{.{
        .source_id = "empty-source",
        .kind = .@"unmanaged-root",
        .locator = path,
        .observations = &.{evidence.value},
    }}, .{});
    defer allocator.free(encoded);
    try std.testing.expectError(
        error.PreparationSourceUncoordinated,
        storage_preparation_sources.Declared.open(
            allocator,
            std.testing.io,
            encoded,
            &plans.parameters,
            .{
                .closure = &plans.closure,
                .entry_path = "plain.json",
                .target = .{ .store_id = "managed-target", .generation = "empty" },
                .limits = .{
                    .bundle = .{ .payload_bytes = 1024 * 1024 },
                    .evidence_bytes = 1024 * 1024,
                    .snapshot_bytes = 1024 * 1024,
                    .capture_bytes = 1024 * 1024,
                },
            },
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, ".ledger", .{}),
    );
}

fn expectExplicitSourceSelection(
    encoded: []const u8,
    descriptors: []const storage_sources.Source,
    held: *const storage_preparation_sources.Declared,
    plans: *const PlainPlans,
    options: storage_preparation_sources.Options,
) !void {
    const allocator = std.testing.allocator;
    const reordered = try storage_sources.encode(
        allocator,
        &.{ descriptors[1], descriptors[0] },
        .{},
    );
    defer allocator.free(reordered);
    var repeated = try storage_preparation_sources.Declared.open(
        allocator,
        std.testing.io,
        reordered,
        &plans.parameters,
        options,
    );
    defer repeated.deinit();
    try std.testing.expectEqualStrings(held.captured.manifest, repeated.captured.manifest);
    var restricted = options;
    restricted.established_source_id = descriptors[1].source_id;
    try std.testing.expectError(
        error.PreparationReconciliationRequired,
        storage_preparation_sources.Declared.open(
            allocator,
            std.testing.io,
            encoded,
            &plans.parameters,
            restricted,
        ),
    );
    restricted.established_source_id = "unknown-source";
    try std.testing.expectError(
        error.InvalidPreparationTarget,
        storage_preparation_sources.Declared.open(
            allocator,
            std.testing.io,
            encoded,
            &plans.parameters,
            restricted,
        ),
    );
    restricted = options;
    restricted.limits.capture_bytes = 0;
    try std.testing.expectError(
        error.CaptureLimitExceeded,
        storage_preparation_sources.Declared.open(
            allocator,
            std.testing.io,
            encoded,
            &plans.parameters,
            restricted,
        ),
    );
}

test "transport preserves original snapshots across repeated native imports" {
    const allocator = std.testing.allocator;
    var scope = storage_root.Scope.init(.init(std.testing.io, .cwd()));
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    try appendPlainCreatedEvent(&scope, &plans, path);
    var evidence = try BundleObservationFixture.init(path);
    defer evidence.deinit();
    var source = try storage_root.SourceRoot.open(allocator, std.testing.io, path, null);
    defer source.deinit();
    var admitted = try evidence.admit(&source);
    defer admitted.deinit();
    var older = try captureTransportSource(&source, &admitted, &plans);
    defer older.deinit();
    try appendPlainEvent(&scope, &plans, path);
    var newer = try captureTransportSource(&source, &admitted, &plans);
    defer newer.deinit();
    try std.Io.Dir.cwd().deleteFile(std.testing.io, evidence.path);
    const options: storage_transport.MergeOptions = .{
        .target = .{ .store_id = "managed-target", .generation = "transport-original" },
        .limits = .{ .payload_bytes = 1024 * 1024, .manifest_bytes = 64 * 1024 },
        .max_input_bytes = 4 * 1024 * 1024,
    };
    var merged = try storage_transport.merge(
        allocator,
        &.{ &older, &newer },
        &plans.parameters,
        options,
    );
    defer merged.deinit();
    var manifest = try storage_bundle.parse(allocator, merged.manifest, options.limits);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 2), manifest.description.sources.len);
    try std.testing.expectEqual(@as(usize, 1), manifest.description.observations.len);
    try std.testing.expectEqual(@as(usize, 1), manifest.description.evidence_subjects.len);
    for (manifest.description.sources) |original| {
        try std.testing.expectEqualStrings("native-source", original.subject.source_id);
        try std.testing.expectEqualStrings(path, original.subject.locator);
    }
    var reversed = try storage_transport.merge(
        allocator,
        &.{ &newer, &older },
        &plans.parameters,
        options,
    );
    defer reversed.deinit();
    try std.testing.expectEqualStrings(merged.manifest, reversed.manifest);
    try exerciseTransportRetries(&merged, &older, &newer, &plans, options);
    try expectTransportLimits(&older, &newer, &plans, options);
    try expectTransportPreservesPrimary(&older, &newer, &plans, options);
    try exerciseTransportReadback(&merged, &plans, options);
}

fn expectTransportPreservesPrimary(
    older: *const storage_bundle.Captured,
    newer: *const storage_bundle.Captured,
    plans: *const PlainPlans,
    options: storage_transport.MergeOptions,
) !void {
    const allocator = std.testing.allocator;
    const binding = try custody.bindingRelativePathAlloc(allocator, "example/plain.jsonl");
    defer allocator.free(binding);
    var replacements: [2]CapturedReplacement = undefined;
    for ([_][]const u8{ "example/plain.jsonl", binding }, &replacements) |path, *replacement| {
        var found = false;
        for (newer.files) |file| {
            if (!std.mem.eql(u8, file.descriptor.path, path)) continue;
            replacement.* = .{ .path = path, .content = file.content };
            found = true;
        }
        try std.testing.expect(found);
    }
    var extended = try replaceCapturedFiles(older, &replacements);
    defer extended.deinit();
    var validated = try storage_admission.prepare(allocator, &extended, &plans.parameters, .{
        .limits = options.limits,
    });
    defer validated.deinit();
    try std.testing.expectEqual(@as(usize, 2), validated.records_validated);
    try std.testing.expectError(error.PreparationReconciliationRequired, storage_transport.merge(
        allocator,
        &.{&extended},
        &plans.parameters,
        options,
    ));
}

fn captureTransportSource(
    source: *storage_root.SourceRoot,
    evidence: *const storage_source_admission.RootAdmission,
    plans: *const PlainPlans,
) !storage_bundle.Captured {
    const allocator = std.testing.allocator;
    var snapshot = try storage_preparation.DeclaredSnapshot.load(
        allocator,
        source,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        1024 * 1024,
    );
    defer snapshot.deinit(allocator);
    return storage_bundle.captureDeclared(allocator, &snapshot, .{
        .closure = &plans.closure,
        .entry_path = "plain.json",
        .target = .{ .store_id = "managed-target", .generation = "transport-original" },
        .evidence = evidence,
        .limits = .{ .payload_bytes = 1024 * 1024, .manifest_bytes = 64 * 1024 },
    });
}

fn exerciseTransportRetries(
    merged: *const storage_bundle.Captured,
    older: *const storage_bundle.Captured,
    newer: *const storage_bundle.Captured,
    plans: *const PlainPlans,
    options: storage_transport.MergeOptions,
) !void {
    const allocator = std.testing.allocator;
    var current = try storage_transport.merge(allocator, &.{merged}, &plans.parameters, options);
    defer current.deinit();
    for (0..100) |_| {
        var next = try storage_transport.merge(
            allocator,
            &.{ &current, newer, older },
            &plans.parameters,
            options,
        );
        errdefer next.deinit();
        try std.testing.expectEqualStrings(merged.manifest, next.manifest);
        try std.testing.expectEqualStrings(merged.identity, next.identity);
        try std.testing.expectEqual(merged.payload_bytes, next.payload_bytes);
        try std.testing.expectEqual(merged.files.len, next.files.len);
        current.deinit();
        current = next;
    }
    var candidate = try storage_admission.prepare(allocator, &current, &plans.parameters, .{
        .limits = options.limits,
    });
    defer candidate.deinit();
    try std.testing.expectEqual(@as(usize, 2), candidate.records_validated);
}

fn expectTransportLimits(
    older: *const storage_bundle.Captured,
    newer: *const storage_bundle.Captured,
    plans: *const PlainPlans,
    options: storage_transport.MergeOptions,
) !void {
    const allocator = std.testing.allocator;
    var restricted = options;
    restricted.established_input = 0;
    try std.testing.expectError(error.PreparationReconciliationRequired, storage_transport.merge(
        allocator,
        &.{ older, newer },
        &plans.parameters,
        restricted,
    ));
    restricted = options;
    restricted.max_input_bytes = 0;
    try std.testing.expectError(error.TransportInputLimitExceeded, storage_transport.merge(
        allocator,
        &.{ older, newer },
        &plans.parameters,
        restricted,
    ));
    restricted.max_input_bytes = older.manifest.len;
    for (older.files) |file| restricted.max_input_bytes += file.content.len;
    var exact = try storage_transport.merge(allocator, &.{older}, &plans.parameters, restricted);
    defer exact.deinit();
    restricted.max_input_bytes -= 1;
    try std.testing.expectError(error.TransportInputLimitExceeded, storage_transport.merge(
        allocator,
        &.{older},
        &plans.parameters,
        restricted,
    ));
}

fn exerciseTransportReadback(
    captured: *const storage_bundle.Captured,
    plans: *const PlainPlans,
    options: storage_transport.MergeOptions,
) !void {
    const allocator = std.testing.allocator;
    var first = try BundleTargetFixture.init();
    defer first.deinit();
    var published = try first.publish(captured);
    defer published.deinit(allocator);
    try std.testing.expectEqual(.committed, published.receipt.semantic);
    try std.testing.expectEqual(null, published.verification_error);
    const descriptor: storage_sources.Source = .{
        .source_id = "transport-location-one",
        .kind = .@"preservation-bundle",
        .locator = first.path,
        .manifest_digest = captured.identity,
        .observations = &.{},
    };
    var loaded = try storage_transport.Loaded.open(
        allocator,
        std.testing.io,
        descriptor,
        options.limits,
    );
    defer loaded.deinit();
    try loaded.revalidate();
    try std.testing.expectEqualStrings(captured.manifest, loaded.captured.manifest);
    try expectTransportObservationAdmission(descriptor, captured, options.limits);
    var second = try BundleTargetFixture.init();
    defer second.deinit();
    var copied = try second.publish(&loaded.captured);
    defer copied.deinit(allocator);
    try std.testing.expectEqual(.committed, copied.receipt.semantic);
    try std.testing.expectEqual(null, copied.verification_error);
    var moved = descriptor;
    moved.source_id = "transport-location-two";
    moved.locator = second.path;
    var reloaded = try storage_transport.Loaded.open(
        allocator,
        std.testing.io,
        moved,
        options.limits,
    );
    defer reloaded.deinit();
    var merged = try storage_transport.merge(
        allocator,
        &.{ &reloaded.captured, &loaded.captured },
        &plans.parameters,
        options,
    );
    defer merged.deinit();
    try std.testing.expectEqualStrings(captured.manifest, merged.manifest);
    try exerciseBoundRestoration(&merged, plans);
}

fn expectTransportObservationAdmission(
    descriptor: storage_sources.Source,
    captured: *const storage_bundle.Captured,
    limits: storage_bundle.Limits,
) !void {
    const allocator = std.testing.allocator;
    var manifest = try storage_bundle.parse(allocator, captured.manifest, limits);
    defer manifest.deinit();
    var asserted = descriptor;
    asserted.observations = manifest.description.observations;
    var verified = try storage_transport.Loaded.open(allocator, std.testing.io, asserted, limits);
    defer verified.deinit();
    try std.testing.expectEqualStrings(captured.identity, verified.captured.identity);
    var invalid = manifest.description.observations[0];
    invalid.observation_id = "invented-original";
    asserted.observations = &.{invalid};
    try std.testing.expectError(error.BundleObservationMismatch, storage_transport.Loaded.open(
        allocator,
        std.testing.io,
        asserted,
        limits,
    ));
}

const DeclaredGroupEvidence = struct {
    evidence: [4]BundleObservationFixture,
    admitted: [4]storage_source_admission.RootAdmission,

    fn init(sources: *const [4]storage_root.SourceRoot) !DeclaredGroupEvidence {
        var result: DeclaredGroupEvidence = undefined;
        var opened: usize = 0;
        errdefer {
            for (result.admitted[0..opened]) |*admitted| admitted.deinit();
            for (result.evidence[0..opened]) |*evidence| evidence.deinit();
        }
        const ids = [_][]const u8{ "origin-a", "origin-b", "origin-c", "origin-divergent" };
        for (sources, ids, 0..) |*source, id, index| {
            result.evidence[index] = try BundleObservationFixture.initAs(source.locator, id);
            result.admitted[index] = result.evidence[index].admit(source) catch |err| {
                result.evidence[index].deinit();
                return err;
            };
            opened += 1;
        }
        return result;
    }

    fn deinit(self: *DeclaredGroupEvidence) void {
        for (&self.admitted) |*admitted| admitted.deinit();
        for (&self.evidence) |*evidence| evidence.deinit();
    }

    fn inputs(
        self: *const DeclaredGroupEvidence,
        snapshots: *[4]storage_preparation.DeclaredSnapshot,
    ) [4]storage_bundle.DeclaredInput {
        var result: [4]storage_bundle.DeclaredInput = undefined;
        for (&result, snapshots, &self.admitted) |*input, *snapshot, *admitted| {
            input.* = .{ .snapshot = snapshot, .evidence = admitted };
        }
        return result;
    }
};

fn exerciseDeclaredGroup(
    plans: *const PlainPlans,
    sources: *[4]storage_root.SourceRoot,
    snapshots: *[4]storage_preparation.DeclaredSnapshot,
) !void {
    const allocator = std.testing.allocator;
    var evidence = try DeclaredGroupEvidence.init(sources);
    defer evidence.deinit();
    const inputs = evidence.inputs(snapshots);
    const options: storage_bundle.GroupOptions = .{
        .closure = &plans.closure,
        .entry_path = "plain.json",
        .target = .{ .store_id = "managed-target", .generation = "group-original" },
        .max_capture_bytes = 4 * 1024 * 1024,
        .limits = .{ .payload_bytes = 1024 * 1024 },
    };
    var captured = try storage_bundle.captureDeclaredGroup(allocator, inputs[0..3], options);
    defer captured.deinit();
    var manifest = try storage_bundle.parse(allocator, captured.manifest, options.limits);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 3), manifest.description.sources.len);
    try std.testing.expectEqual(@as(usize, 3), manifest.description.observations.len);
    try exerciseCapturedAdmission(&captured, plans);
    try expectGroupHistoryCannotShrink(&captured, &snapshots[0], plans);
    try expectGroupSelectionFailures(&inputs, options);
    try expectRepeatedGroupObservation(&inputs, options, plans);
    const unrelated = try sources[0].control.?.createFile(std.testing.io, "unrelated", .{});
    defer unrelated.close(std.testing.io);
    try unrelated.setLength(std.testing.io, 3 * 1024 * 1024 * 1024);
    var reordered = try storage_bundle.captureDeclaredGroup(
        allocator,
        &.{ inputs[2], inputs[1], inputs[0] },
        options,
    );
    defer reordered.deinit();
    try std.testing.expectEqualStrings(captured.identity, reordered.identity);
    try std.testing.expectEqual(captured.payload_bytes, reordered.payload_bytes);
    for (evidence.evidence[0..3]) |item| {
        try std.Io.Dir.cwd().deleteFile(std.testing.io, item.path);
    }
    try exerciseBoundRestoration(&captured, plans);
}

fn expectGroupSelectionFailures(
    inputs: *const [4]storage_bundle.DeclaredInput,
    options: storage_bundle.GroupOptions,
) !void {
    const allocator = std.testing.allocator;
    var restricted = options;
    restricted.established_target = 0;
    try std.testing.expectError(
        error.PreparationReconciliationRequired,
        storage_bundle.captureDeclaredGroup(allocator, inputs[0..3], restricted),
    );
    try std.testing.expectError(
        error.PreparationReconciliationRequired,
        storage_bundle.captureDeclaredGroup(allocator, &.{ inputs[0], inputs[3] }, options),
    );
    restricted = options;
    restricted.max_capture_bytes = 0;
    try std.testing.expectError(error.CaptureLimitExceeded, storage_bundle.captureDeclaredGroup(
        allocator,
        inputs[0..3],
        restricted,
    ));
    restricted = options;
    restricted.limits.sources = 2;
    try std.testing.expectError(error.TooManySources, storage_bundle.captureDeclaredGroup(
        allocator,
        inputs[0..3],
        restricted,
    ));
}

fn expectGroupHistoryCannotShrink(
    captured: *const storage_bundle.Captured,
    shorter: *const storage_preparation.DeclaredSnapshot,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    const binding = try custody.bindingRelativePathAlloc(allocator, "example/plain.jsonl");
    defer allocator.free(binding);
    var truncated = try replaceCapturedFiles(captured, &.{
        .{ .path = "example/plain.jsonl", .content = shorter.slots[0].content },
        .{ .path = binding, .content = shorter.slots[0].binding.bytes },
    });
    defer truncated.deinit();
    try std.testing.expectError(error.PreparationReconciliationRequired, storage_admission.prepare(
        allocator,
        &truncated,
        &plans.parameters,
        .{ .limits = .{ .payload_bytes = 1024 * 1024 } },
    ));
}

fn expectRepeatedGroupObservation(
    inputs: *const [4]storage_bundle.DeclaredInput,
    options: storage_bundle.GroupOptions,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    var descriptor = inputs[0].evidence.descriptor();
    descriptor.source_id = "origin-a-alias";
    var alias = try storage_source_admission.RootAdmission.open(
        allocator,
        std.testing.io,
        descriptor,
        .{ .evidence_bytes = 1024 * 1024 },
    );
    defer alias.deinit();
    var base = try storage_bundle.captureDeclaredGroup(allocator, inputs[0..2], options);
    defer base.deinit();
    var repeated = try storage_bundle.captureDeclaredGroup(allocator, &.{
        inputs[0], inputs[1], .{ .snapshot = inputs[0].snapshot, .evidence = &alias },
    }, options);
    defer repeated.deinit();
    var manifest = try storage_bundle.parse(allocator, repeated.manifest, options.limits);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 2), manifest.description.observations.len);
    try std.testing.expectEqual(@as(usize, 3), manifest.description.evidence_subjects.len);
    try std.testing.expectEqual(@as(usize, 3), manifest.description.sources.len);
    try std.testing.expectEqual(base.payload_bytes, repeated.payload_bytes);
    var candidate = try storage_admission.prepare(allocator, &repeated, &plans.parameters, .{
        .limits = options.limits,
    });
    defer candidate.deinit();
    try std.testing.expectEqual(@as(usize, 2), candidate.records_validated);
}

test "preparation apply coordinates an empty source without mutating read only discovery" {
    const allocator = std.testing.allocator;
    var scope = storage_root.Scope.init(.init(std.testing.io, .cwd()));
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    var source = try storage_root.SourceRoot.open(allocator, std.testing.io, path, null);
    defer source.deinit();
    var observed = try storage_preparation.DeclaredSnapshot.load(
        allocator,
        &source,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        1024 * 1024,
    );
    defer observed.deinit(allocator);
    try std.testing.expect(!observed.coordinated());
    try std.testing.expect(source.control == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(
        std.testing.io,
        ".ledger",
        .{ .follow_symlinks = false },
    ));
    {
        var mutated = false;
        var held = try storage_preparation.DeclaredSnapshot.loadForApply(
            allocator,
            &source,
            &plans.artifact,
            &plans.store,
            &plans.parameters,
            1024 * 1024,
            &mutated,
        );
        defer held.deinit(allocator);
        try std.testing.expect(mutated);
        try std.testing.expect(held.coordinated());
        try std.testing.expectEqual(@as(usize, 1), held.slots.len);
        try std.testing.expect(!held.slots[0].exists);
        try expectConcurrentPreparationRead(&source, &plans);
        try std.testing.expectError(error.LockBusy, appendPlainCreatedEvent(&scope, &plans, path));
    }
    try appendPlainCreatedEvent(&scope, &plans, path);
    var final = try storage_preparation.DeclaredSnapshot.load(
        allocator,
        &source,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        1024 * 1024,
    );
    defer final.deinit(allocator);
    try std.testing.expect(final.slots[0].exists);
    try source.revalidate(path);
}

fn expectConcurrentPreparationRead(
    source: *storage_root.SourceRoot,
    plans: *const PlainPlans,
) !void {
    var mutated = false;
    var held = try storage_preparation.DeclaredSnapshot.loadForApply(
        std.testing.allocator,
        source,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        1024 * 1024,
        &mutated,
    );
    defer held.deinit(std.testing.allocator);
    try std.testing.expect(!mutated);
    try std.testing.expect(held.coordinated());
}

test "preparation apply observes a supplied source populated after discovery" {
    const allocator = std.testing.allocator;
    var scope = storage_root.Scope.init(.init(std.testing.io, .cwd()));
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    var source = try storage_root.SourceRoot.open(allocator, std.testing.io, path, null);
    defer source.deinit();
    try std.testing.expect(source.control == null);
    try appendPlainCreatedEvent(&scope, &plans, path);
    var mutated = false;
    var selected = try storage_preparation.DeclaredSnapshot.loadForApply(
        allocator,
        &source,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        1024 * 1024,
        &mutated,
    );
    defer selected.deinit(allocator);
    try std.testing.expect(!mutated);
    try std.testing.expect(selected.coordinated());
    try std.testing.expect(selected.slots[0].exists);
    try std.testing.expectEqual(@as(usize, 1), selected.slots[0].binding.rows.len);
    try source.revalidate(path);
}

test "preparation refuses a crashed native write until its recovery completes" {
    const allocator = std.testing.allocator;
    var scope = storage_root.Scope.init(.init(std.testing.io, .cwd()));
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    try appendPlainCreatedEvent(&scope, &plans, root);
    PublicationStageFault.stage_handle = null;
    var table = std.testing.io.vtable.*;
    table.dirCreateFile = PublicationStageFault.create;
    table.fileSync = PublicationStageFault.sync;
    var interrupted_scope = storage_root.Scope.init(.init(
        .{ .userdata = std.testing.io.userdata, .vtable = &table },
        .cwd(),
    ));
    try std.testing.expectError(error.InputOutput, appendPlainEvent(
        &interrupted_scope,
        &plans,
        root,
    ));
    var source = try storage_root.SourceRoot.open(allocator, std.testing.io, root, null);
    defer source.deinit();
    {
        var selected = try storage_preparation.DeclaredSnapshot.load(
            allocator,
            &source,
            &plans.artifact,
            &plans.store,
            &plans.parameters,
            1024 * 1024,
        );
        defer selected.deinit(allocator);
        try std.testing.expect(selected.coordinated());
        var probe = DeclaredCaptureProbe{ .source = &source };
        try std.testing.expectError(error.PreparationSourceRecoveryRequired, selected.visitFiles(
            allocator,
            &probe,
        ));
        try std.testing.expectEqual(@as(usize, 0), probe.files);
    }
    try std.testing.expect(try transaction.recoverRepositoryTransactions(&scope, allocator, root));
    const recovered = try captureDeclaredFixture(&source, &plans);
    try std.testing.expectEqual(@as(usize, 3), recovered.files);
}

const unbound_plain_prefix =
    "{\"kind\":\"created\",\"value\":{\"id\":\"item-1\",\"revision\":1}}";
const unbound_plain_history = unbound_plain_prefix ++ "\r\n" ++
    "{\"kind\":\"updated\",\"value\":{\"id\":\"item-1\",\"revision\":1}}";

test "unbound preparation selects complete record prefixes and rejects divergent histories" {
    const allocator = std.testing.allocator;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var prefix = try UnboundPreparationFixture.init(unbound_plain_prefix);
    defer prefix.deinit();
    var complete = try UnboundPreparationFixture.init(unbound_plain_history);
    defer complete.deinit();
    var different = try UnboundPreparationFixture.init(
        "{\"kind\":\"created\",\"value\":{\"id\":\"other\",\"revision\":1}}",
    );
    defer different.deinit();
    var first = try prefix.load(&plans);
    defer first.deinit(allocator);
    var second = try complete.load(&plans);
    defer second.deinit(allocator);
    var third = try different.load(&plans);
    defer third.deinit(allocator);
    const select = storage_preparation.selectBoundHistory;
    try std.testing.expectEqual(@as(usize, 1), try select(&.{ &first, &second }, null));
    try std.testing.expectEqual(@as(usize, 0), try select(&.{ &second, &first }, null));
    try std.testing.expectError(
        error.PreparationReconciliationRequired,
        select(&.{ &first, &third }, null),
    );
    try std.testing.expectError(
        error.PreparationReconciliationRequired,
        select(&.{ &first, &second }, 0),
    );
}

const UnboundPreparationFixture = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    source: storage_root.SourceRoot,

    fn init(content: []const u8) !UnboundPreparationFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try writeUnboundPlain(tmp.dir, content);
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        errdefer std.testing.allocator.free(path);
        return .{
            .tmp = tmp,
            .path = path,
            .source = try storage_root.SourceRoot.open(
                std.testing.allocator,
                std.testing.io,
                path,
                null,
            ),
        };
    }

    fn deinit(self: *UnboundPreparationFixture) void {
        self.source.deinit();
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn load(
        self: *UnboundPreparationFixture,
        plans: *const PlainPlans,
    ) !storage_preparation.DeclaredSnapshot {
        var mutated = false;
        return storage_preparation.DeclaredSnapshot.loadForApply(
            std.testing.allocator,
            &self.source,
            &plans.artifact,
            &plans.store,
            &plans.parameters,
            1024 * 1024,
            &mutated,
        );
    }
};

test "unbound preparation captures original framing and admits staged custody through native law" {
    const allocator = std.testing.allocator;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeUnboundPlain(tmp.dir, unbound_plain_history);
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    var source = try storage_root.SourceRoot.open(allocator, std.testing.io, path, null);
    defer source.deinit();
    var evidence = try BundleObservationFixture.init(path);
    defer evidence.deinit();
    var mutated = false;
    var selected = try storage_preparation.DeclaredSnapshot.loadForApply(
        allocator,
        &source,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        1024 * 1024,
        &mutated,
    );
    defer selected.deinit(allocator);
    try std.testing.expect(mutated);
    try std.testing.expect(selected.coordinated());
    try std.testing.expect(!selected.slots[0].binding.exists);
    try std.testing.expectEqualStrings(unbound_plain_history, selected.slots[0].content);
    try expectExplicitUnboundAdmission(&source, &plans);
    var admitted = try evidence.admit(&source);
    defer admitted.deinit();
    var captured = try storage_bundle.captureDeclared(allocator, &selected, .{
        .closure = &plans.closure,
        .entry_path = "plain.json",
        .target = .{ .store_id = "managed-target", .generation = "unbound-admission" },
        .evidence = &admitted,
        .limits = .{ .payload_bytes = 1024 * 1024 },
    });
    defer captured.deinit();
    try exerciseCapturedAdmission(&captured, &plans);
    try exerciseUnboundPublication(&captured, &plans);
    try exerciseCombinedUnboundPublication(&captured, &plans);
    try std.testing.expectEqual(@as(usize, 3), captured.files.len);
    var slot_seen = false;
    for (captured.files) |file| {
        try std.testing.expect(!std.mem.startsWith(u8, file.descriptor.path, ".bindings/"));
        if (!std.mem.eql(u8, file.descriptor.path, "example/plain.jsonl")) continue;
        slot_seen = true;
        try std.testing.expectEqualStrings(unbound_plain_history, file.content);
        var staged = std.testing.tmpDir(.{});
        defer staged.cleanup();
        try writeUnboundPlain(staged.dir, file.content);
        const staged_path = try staged.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(staged_path);
        var scope = storage_root.Scope.init(.init(std.testing.io, .cwd()));
        try bindPlainStore(&scope, &plans, staged_path);
        try expectPlainProjection(&scope, &plans, staged_path);
    }
    try std.testing.expect(slot_seen);
}

fn exerciseCapturedAdmission(
    captured: *const storage_bundle.Captured,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    const options: storage_admission.Options = .{ .limits = .{ .payload_bytes = 1024 * 1024 } };
    var candidate = try storage_admission.prepare(allocator, captured, &plans.parameters, options);
    defer candidate.deinit();
    var retry = try storage_admission.prepare(allocator, captured, &plans.parameters, options);
    defer retry.deinit();
    try std.testing.expectEqualStrings(candidate.identity, retry.identity);
    try std.testing.expectEqual(@as(usize, 2), candidate.records_validated);
    const binding = try custody.bindingRelativePathAlloc(allocator, "example/plain.jsonl");
    defer allocator.free(binding);
    var found_binding = false;
    for (candidate.files) |file| {
        try std.testing.expect(!std.mem.startsWith(u8, file.path, ".evidence/"));
        if (std.mem.eql(u8, file.path, binding)) found_binding = file.content != null;
        for (captured.files) |original| {
            if (!std.mem.eql(u8, file.path, original.descriptor.path)) continue;
            try std.testing.expectEqualStrings(original.content, file.content.?);
        }
    }
    try std.testing.expect(found_binding);
    try expectChangedEvidenceSubject(captured, plans);
}

fn expectForeignCaptureEvidence(
    snapshot: *storage_preparation.DeclaredSnapshot,
    options: storage_bundle.DeclaredOptions,
) !void {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    var source = try storage_root.SourceRoot.open(allocator, std.testing.io, path, null);
    defer source.deinit();
    var evidence = try BundleObservationFixture.init(path);
    defer evidence.deinit();
    var admitted = try evidence.admit(&source);
    defer admitted.deinit();
    var invalid = options;
    invalid.evidence = &admitted;
    try std.testing.expectError(error.SourceAdmissionMismatch, storage_bundle.captureDeclared(
        allocator,
        snapshot,
        invalid,
    ));
}

fn expectChangedEvidenceSubject(
    captured: *const storage_bundle.Captured,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    const limits: storage_bundle.Limits = .{ .payload_bytes = 1024 * 1024 };
    var manifest = try storage_bundle.parse(allocator, captured.manifest, limits);
    defer manifest.deinit();
    const subjects = try allocator.dupe(
        storage_bundle.EvidenceSubject,
        manifest.description.evidence_subjects,
    );
    defer allocator.free(subjects);
    try std.testing.expect(subjects.len != 0);
    subjects[0].subject.locator = "/unrelated/original/root";
    var description = manifest.description;
    description.evidence_subjects = subjects;
    const bytes = try storage_bundle.encode(allocator, description, limits);
    defer allocator.free(bytes);
    var changed = try storage_bundle.parse(allocator, bytes, limits);
    defer changed.deinit();
    var invalid = captured.*;
    invalid.manifest = bytes;
    invalid.identity = changed.digest;
    try std.testing.expectError(error.SourceEvidenceRootMismatch, storage_admission.prepare(
        allocator,
        &invalid,
        &plans.parameters,
        .{ .limits = limits },
    ));
    var target = try BundleTargetFixture.init();
    defer target.deinit();
    var before = try target.budget.inspect(allocator);
    defer before.deinit();
    try std.testing.expectError(error.SourceEvidenceRootMismatch, target.publish(&invalid));
    var after = try target.budget.inspect(allocator);
    defer after.deinit();
    try std.testing.expectEqual(before.parsed.value.generation, after.parsed.value.generation);
}

fn exerciseUnboundPublication(
    captured: *const storage_bundle.Captured,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    var fixture = try BundleTargetFixture.init();
    defer fixture.deinit();
    var preserved = try fixture.publish(captured);
    defer preserved.deinit(allocator);
    try std.testing.expectEqual(.committed, preserved.receipt.semantic);
    try exerciseCustodyPublication(&fixture, captured.identity, plans);
    try exerciseConflictingCustody(captured, plans);
    var invalid = try replaceCapturedSlot(captured, "");
    defer invalid.deinit();
    try std.testing.expectError(error.ExistingStoreEmpty, storage_admission.prepare(
        allocator,
        &invalid,
        &plans.parameters,
        .{ .limits = .{ .payload_bytes = 1024 * 1024 } },
    ));
}

fn exerciseCombinedUnboundPublication(
    captured: *const storage_bundle.Captured,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    var fixture = try BundleTargetFixture.init();
    defer fixture.deinit();
    var manifest = try storage_bundle.parse(
        allocator,
        captured.manifest,
        fixture.publicationOptions().limits,
    );
    defer manifest.deinit();
    const charge = try storage_admission.installationCharge(
        allocator,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        manifest.description.target,
        fixture.publicationOptions().limits,
    );
    var reservation = try storage_bundle.Reservation.acquireCharge(
        allocator,
        &fixture.target,
        "unbound-combined-installation",
        fixture.publicationOptions(),
        charge,
    );
    defer reservation.deinit();
    try interruptCombinedInstallation(&fixture, captured, plans, &reservation);
    for (0..2) |index| {
        var result = try storage_admission.installCaptured(
            allocator,
            &fixture.target,
            captured,
            &plans.parameters,
            .{
                .publication = fixture.publicationOptions(),
                .expected_projection = expected_plain_projection,
            },
            &reservation,
        );
        defer result.deinit(allocator);
        try std.testing.expectEqual(.committed, result.receipt.semantic);
        try std.testing.expectEqual(null, result.receipt.accounting_error);
        try std.testing.expectEqual(null, result.verification_error);
        if (index > 0) try std.testing.expect(result.receipt.reused);
    }
    var scope = fixture.target.scope().?;
    try expectPlainProjection(&scope, plans, ".");
    try expectCombinedPublication(&fixture, captured);
    var resolved = try storage.resolve(allocator, &plans.store, &plans.parameters);
    defer resolved.deinit(allocator);
    const bound = try transaction.unboundBindingSizeBound(
        allocator,
        &plans.artifact,
        resolved.slotSlice()[0],
        "bind-existing",
        &plans.parameters,
        &plans.protocol,
        0,
    );
    const path = try custody.bindingRelativePathAlloc(allocator, "example/plain.jsonl");
    defer allocator.free(path);
    const file = try fixture.target.openControlFile(path);
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expect(stat.size <= bound);
}

fn interruptCombinedInstallation(
    fixture: *BundleTargetFixture,
    captured: *const storage_bundle.Captured,
    plans: *const PlainPlans,
    reservation: *const storage_bundle.Reservation,
) !void {
    PublicationStageFault.stage_handle = null;
    var table = std.testing.io.vtable.*;
    table.dirCreateFile = PublicationStageFault.create;
    table.fileSync = PublicationStageFault.sync;
    fixture.target.io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    defer fixture.target.io = std.testing.io;
    var interrupted = try storage_admission.installCaptured(
        std.testing.allocator,
        &fixture.target,
        captured,
        &plans.parameters,
        .{
            .publication = fixture.publicationOptions(),
            .expected_projection = expected_plain_projection,
        },
        reservation,
    );
    defer interrupted.deinit(std.testing.allocator);
    try std.testing.expectEqual(.recovery_required, interrupted.receipt.semantic);
    try std.testing.expectEqual(error.InputOutput, interrupted.receipt.failure.?);
    try std.testing.expectError(error.FileNotFound, fixture.target.openControlFile(
        "example/plain.jsonl",
    ));
    const manifest_path = try std.testing.allocator.print(
        ".preservation/manifests/{s}.json",
        .{captured.identity[7..]},
    );
    defer std.testing.allocator.free(manifest_path);
    try std.testing.expectError(error.FileNotFound, fixture.target.openControlFile(manifest_path));
    var pending = try fixture.budget.inspect(std.testing.allocator);
    defer pending.deinit();
    try std.testing.expectEqual(@as(usize, 1), pending.parsed.value.reservations.len);
    try std.testing.expectEqual(reservation.request.charge, pending.reserved);
}

fn exerciseConflictingCustody(
    captured: *const storage_bundle.Captured,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    var fixture = try BundleTargetFixture.init();
    defer fixture.deinit();
    var preserved = try fixture.publish(captured);
    defer preserved.deinit(allocator);
    var scope = fixture.target.scope().?;
    try appendPlainCreatedEventFor(&scope, plans, ".", "different");
    var before = try fixture.budget.inspect(allocator);
    defer before.deinit();
    try std.testing.expectError(
        error.PreparationReconciliationRequired,
        storage_admission.applyPublished(
            allocator,
            &fixture.target,
            captured.identity,
            &plans.parameters,
            .{ .publication = fixture.publicationOptions() },
        ),
    );
    var after = try fixture.budget.inspect(allocator);
    defer after.deinit();
    try std.testing.expectEqual(before.parsed.value.generation, after.parsed.value.generation);
    try std.testing.expectEqual(before.used.logical_total, after.used.logical_total);
    const bytes = try fixture.tmp.dir.readFileAlloc(
        std.testing.io,
        ".ledger/example/plain.jsonl",
        allocator,
        .limited(4096),
    );
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "different") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "item-1") == null);
}

fn exerciseBoundRestoration(
    captured: *const storage_bundle.Captured,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    var fixture = try BundleTargetFixture.init();
    defer fixture.deinit();
    var scope = fixture.target.scope().?;
    try appendPlainCreatedEvent(&scope, plans, ".");
    try appendPlainEvent(&scope, plans, ".");
    const binding = try custody.bindingRelativePathAlloc(allocator, "example/plain.jsonl");
    defer allocator.free(binding);
    const path = try std.fs.path.join(allocator, &.{ ".ledger", binding });
    defer allocator.free(path);
    const before = try fixture.tmp.dir.readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(custody.binding_max_bytes),
    );
    defer allocator.free(before);
    try fixture.tmp.dir.deleteFile(std.testing.io, ".ledger/example/plain.jsonl");
    var tampered = try replaceCapturedSlot(captured, "{}\n");
    defer tampered.deinit();
    try std.testing.expectError(error.StoreBindingRevisionMismatch, storage_admission.prepare(
        allocator,
        &tampered,
        &plans.parameters,
        .{ .limits = .{ .payload_bytes = 1024 * 1024 } },
    ));
    var preserved = try fixture.publish(captured);
    defer preserved.deinit(allocator);
    try std.testing.expectEqual(.committed, preserved.receipt.semantic);
    var target_custody = try inspectBoundTarget(&fixture, captured, plans);
    defer target_custody.deinit(allocator);
    var publication_options = fixture.publicationOptions();
    publication_options.preparation = &target_custody;
    var restored = try storage_admission.applyPublished(
        allocator,
        &fixture.target,
        captured.identity,
        &plans.parameters,
        .{ .publication = publication_options },
    );
    defer restored.deinit(allocator);
    try std.testing.expectEqual(.committed, restored.receipt.semantic);
    try std.testing.expectEqual(null, restored.verification_error);
    try std.testing.expectEqual(null, restored.receipt.accounting_error);
    const after = try fixture.tmp.dir.readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(custody.binding_max_bytes),
    );
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try expectPlainProjection(&scope, plans, ".");
}

fn inspectBoundTarget(
    fixture: *BundleTargetFixture,
    captured: *const storage_bundle.Captured,
    plans: *const PlainPlans,
) !storage_preparation.Publication {
    const allocator = std.testing.allocator;
    var content: ?[]const u8 = null;
    for (captured.files) |file| {
        if (std.mem.eql(u8, file.descriptor.path, "example/plain.jsonl")) content = file.content;
    }
    const bytes = content orelse return error.TestExpectedEventSlot;
    try expectBoundTargetRejectsInvalid(fixture, plans, bytes);
    var target = try storage_preparation.TargetSnapshot.load(
        allocator,
        &fixture.target,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        &.{.{ .slot_name = "events", .content = bytes }},
        budgetPreparationOptions(fixture),
    );
    defer target.deinit(allocator);
    try std.testing.expect(target.observed.coordinated());
    try std.testing.expectEqual(.target, target.observed.role);
    try std.testing.expect(!target.observed.slots[0].exists);
    try std.testing.expect(target.observed.slots[0].binding.exists);
    try std.testing.expectEqualStrings(bytes, target.observed.slots[0].content);
    try std.testing.expectError(
        error.PreparationTargetIsNotSource,
        storage_preparation.selectBoundHistory(&.{&target.observed}, null),
    );
    try std.testing.expectError(error.PreparationTargetIsNotSource, storage_bundle.captureDeclared(
        allocator,
        &target.observed,
        .{
            .closure = &plans.closure,
            .entry_path = "plain.json",
            .target = .{ .store_id = "managed-target", .generation = "restoration" },
            .limits = .{ .payload_bytes = 1024 * 1024 },
        },
    ));
    return target.releaseForPublication(allocator);
}

fn expectBoundTargetRejectsInvalid(
    fixture: *BundleTargetFixture,
    plans: *const PlainPlans,
    bytes: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const options = budgetPreparationOptions(fixture);
    try std.testing.expectError(
        error.StoreBindingWithoutSlot,
        storage_preparation.DeclaredSnapshot.loadWithContext(
            allocator,
            &fixture.target,
            &plans.artifact,
            &plans.store,
            &plans.parameters,
            options,
        ),
    );
    const Cases = struct {
        inputs: []const storage_preparation.RestorationInput,
        expected: anyerror,
    };
    const first_line = 1 + (std.mem.indexOfScalar(u8, bytes, '\n') orelse
        return error.TestExpectedLine);
    try std.testing.expect(first_line < bytes.len);
    const cases = [_]Cases{
        .{ .inputs = &.{}, .expected = error.RestorationCandidateRequired },
        .{
            .inputs = &.{.{ .slot_name = "events", .content = "{}\n" }},
            .expected = error.StoreBindingRevisionMismatch,
        },
        .{
            .inputs = &.{.{ .slot_name = "events", .content = bytes[0..first_line] }},
            .expected = error.StoreBindingRevisionMismatch,
        },
        .{
            .inputs = &.{.{ .slot_name = "unknown", .content = bytes }},
            .expected = error.InvalidRestorationInput,
        },
    };
    for (cases) |case| {
        try std.testing.expectError(case.expected, storage_preparation.TargetSnapshot.load(
            allocator,
            &fixture.target,
            &plans.artifact,
            &plans.store,
            &plans.parameters,
            case.inputs,
            options,
        ));
    }
}

const CapturedReplacement = struct { path: []const u8, content: []const u8 };

fn replaceCapturedSlot(
    original: *const storage_bundle.Captured,
    content: []const u8,
) !storage_bundle.Captured {
    return replaceCapturedFiles(original, &.{.{
        .path = "example/plain.jsonl",
        .content = content,
    }});
}

fn replaceCapturedFiles(
    original: *const storage_bundle.Captured,
    replacements: []const CapturedReplacement,
) !storage_bundle.Captured {
    const allocator = std.testing.allocator;
    const limits: storage_bundle.Limits = .{ .payload_bytes = 1024 * 1024 };
    var manifest = try storage_bundle.parse(allocator, original.manifest, limits);
    defer manifest.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const capacity = try owned.alloc(
        storage_bundle.CapturedFile,
        original.files.len + replacements.len,
    );
    @memcpy(capacity[0..original.files.len], original.files);
    var count = original.files.len;
    var replaced: usize = 0;
    for (capacity[0..original.files.len]) |*file| {
        for (replacements) |replacement| {
            if (!std.mem.eql(u8, file.descriptor.path, replacement.path)) continue;
            replaced += 1;
            var retained = file.*;
            retained.descriptor.path = try owned.print(
                ".evidence/{s}.json",
                .{retained.descriptor.content_id[7..]},
            );
            var exists = false;
            for (capacity[0..count]) |prior| {
                if (std.mem.eql(u8, prior.descriptor.path, retained.descriptor.path)) exists = true;
            }
            if (!exists) {
                capacity[count] = retained;
                count += 1;
            }
            file.content = try owned.dupe(u8, replacement.content);
            file.descriptor.byte_length = replacement.content.len;
            file.descriptor.content_id = try definition_core.canonical_json.digestBytesAlloc(
                owned,
                replacement.content,
            );
        }
    }
    try std.testing.expectEqual(replacements.len, replaced);
    const files = capacity[0..count];
    const descriptors = try owned.alloc(storage_bundle.File, files.len);
    for (files, descriptors) |file, *descriptor| descriptor.* = file.descriptor;
    var description = manifest.description;
    description.files = descriptors;
    const bytes = try storage_bundle.encode(owned, description, limits);
    var rewritten = try storage_bundle.parse(allocator, bytes, limits);
    defer rewritten.deinit();
    const identity = try owned.dupe(u8, rewritten.digest);
    return .{
        .arena = arena,
        .manifest = bytes,
        .identity = identity,
        .files = files,
        .payload_bytes = rewritten.payload_bytes,
    };
}

fn writeUnboundPlain(directory: std.Io.Dir, bytes: []const u8) !void {
    try directory.createDirPath(std.testing.io, ".ledger/example");
    try directory.writeFile(std.testing.io, .{
        .sub_path = ".ledger/example/plain.jsonl",
        .data = bytes,
    });
}

fn expectExplicitUnboundAdmission(
    source: *storage_root.SourceRoot,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    var operations = [_]storage.Operation{
        plans.store.findOperation("append").?.*,
        plans.store.findOperation("bind-existing").?.*,
        plans.store.findOperation("bind-existing").?.*,
    };
    var duplicate_name = "other-binding".*;
    operations[2].name = &duplicate_name;
    var ambiguous = plans.store;
    ambiguous.operations = &operations;
    try std.testing.expectError(
        error.PreparationBindingOperationAmbiguous,
        storage_preparation.DeclaredSnapshot.load(
            allocator,
            source,
            &plans.artifact,
            &ambiguous,
            &plans.parameters,
            1024 * 1024,
        ),
    );
    var explicit = try storage_preparation.DeclaredSnapshot.loadWithAdmission(
        allocator,
        source,
        &plans.artifact,
        &ambiguous,
        &plans.parameters,
        1024 * 1024,
        "bind-existing",
    );
    defer explicit.deinit(allocator);
    try std.testing.expectEqualStrings(unbound_plain_history, explicit.slots[0].content);
}

const BundleObservationFixture = struct {
    value: storage_sources.Observation,
    path: []u8,
    digest: []u8,

    fn init(root: []const u8) !BundleObservationFixture {
        return initAs(root, "native-source");
    }

    fn initAs(root: []const u8, source_id: []const u8) !BundleObservationFixture {
        const allocator = std.testing.allocator;
        const bytes = try std.json.Stringify.valueAlloc(allocator, .{
            .source_id = source_id,
            .locator = root,
        }, .{});
        defer allocator.free(bytes);
        const path = try std.fs.path.join(allocator, &.{ root, "source-evidence.json" });
        errdefer allocator.free(path);
        const digest = try definition_core.canonical_json.digestBytesAlloc(allocator, bytes);
        errdefer allocator.free(digest);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
        return .{
            .value = .{
                .observation_id = source_id,
                .evidence_locator = path,
                .evidence_digest = digest,
                .evidence_pointer = "/locator",
                .binding = .{ .root_pointer = "" },
            },
            .path = path,
            .digest = digest,
        };
    }

    fn deinit(self: *BundleObservationFixture) void {
        std.testing.allocator.free(self.path);
        std.testing.allocator.free(self.digest);
    }

    fn admit(
        self: *const BundleObservationFixture,
        source: *const storage_root.SourceRoot,
    ) !storage_source_admission.RootAdmission {
        return storage_source_admission.RootAdmission.open(std.testing.allocator, source.io, .{
            .source_id = self.value.observation_id,
            .kind = if (source.store_id != null) .@"managed-root" else .@"unmanaged-root",
            .locator = source.locator,
            .store_id = source.store_id,
            .observations = &.{self.value},
        }, .{ .evidence_bytes = 1024 * 1024 });
    }
};

const BundleTargetFixture = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    target: storage_root.SourceRoot,
    budget: durable_store.ReservationBudget,

    fn init() !BundleTargetFixture {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(path);
        try tmp.dir.createDir(io, ".ledger", .default_dir);
        try tmp.dir.writeFile(io, .{
            .sub_path = storage_root.marker_name,
            .data = "{\"schema\":\"ledger-storage-root/v1\",\"store_id\":\"managed-target\"}",
        });
        var target = try storage_root.SourceRoot.open(allocator, io, path, "managed-target");
        errdefer target.deinit();
        var provisioned = try durable_store.PrivateDirectory.open(
            .init(io, tmp.dir),
            "budget",
            .create,
        );
        provisioned.deinit();
        const limits: durable_store.ReservationCharge = .{
            .logical_total = 64 * 1024 * 1024,
            .staging = 32 * 1024 * 1024,
            .metadata = 32 * 1024 * 1024,
        };
        const budget = try durable_store.ReservationBudget.initialize(
            .init(io, tmp.dir),
            allocator,
            "budget",
            "bundle-budget",
            .{
                .limits = limits,
                .free_space_scope_id = "fixture-filesystem",
                .minimum_free_bytes = 1024,
                .recovery_reserve_bytes = 1024 * 1024,
                .max_observation_age_ms = 60_000,
            },
            &.{.{ .store_id = "managed-target", .used = .zero, .limits = limits }},
            freeObservation(),
        );
        return .{ .tmp = tmp, .path = path, .target = target, .budget = budget };
    }

    fn deinit(self: *BundleTargetFixture) void {
        self.budget.deinit();
        self.target.deinit();
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn freeObservation() durable_store.ReservationFreeSpaceObservation {
        return .{
            .scope_id = "fixture-filesystem",
            .available_bytes = 1024 * 1024 * 1024,
            .observed_at_ms = @intCast(@divFloor(
                std.Io.Clock.real.now(std.testing.io).nanoseconds,
                1_000_000,
            )),
        };
    }

    fn publish(
        self: *BundleTargetFixture,
        captured: *const storage_bundle.Captured,
    ) !storage_bundle.Published {
        return storage_bundle.publishCaptured(
            std.testing.allocator,
            &self.target,
            captured,
            self.publicationOptions(),
        );
    }

    fn publicationOptions(self: *BundleTargetFixture) storage_bundle.PublishOptions {
        return .{
            .budget = &self.budget,
            .budget_id = "bundle-budget",
            .free_space = freeObservation(),
            .owner = .{ .process_id = 1, .session_id = "bundle-test", .executor = "native-test" },
            .limits = .{ .payload_bytes = 1024 * 1024, .manifest_bytes = 64 * 1024 },
        };
    }
};

fn exerciseBundlePublication(
    captured: *const storage_bundle.Captured,
    successor: *const storage_bundle.Captured,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    var fixture = try BundleTargetFixture.init();
    defer fixture.deinit();
    try interruptBundleStaging(&fixture, captured);
    var first = try fixture.publish(captured);
    defer first.deinit(allocator);
    try std.testing.expect(first.receipt.semantic == .committed);
    try std.testing.expectEqual(null, first.receipt.accounting_error);
    try std.testing.expectEqual(null, first.verification_error);
    var before_retry = try fixture.budget.inspect(allocator);
    defer before_retry.deinit();
    try std.testing.expectEqual(@as(usize, 0), before_retry.parsed.value.reservations.len);
    var retry = try fixture.publish(captured);
    defer retry.deinit(allocator);
    try std.testing.expect(retry.receipt.reused);
    try std.testing.expectEqual(null, retry.verification_error);
    try std.testing.expectEqualStrings(
        first.receipt.transaction.transaction_id,
        retry.receipt.transaction.transaction_id,
    );
    var after_retry = try fixture.budget.inspect(allocator);
    defer after_retry.deinit();
    try std.testing.expectEqual(
        before_retry.parsed.value.generation,
        after_retry.parsed.value.generation,
    );
    try std.testing.expectEqual(before_retry.used.logical_total, after_retry.used.logical_total);
    var next = try fixture.publish(successor);
    defer next.deinit(allocator);
    try std.testing.expect(next.receipt.semantic == .committed);
    try std.testing.expectEqual(null, next.verification_error);
    var after_successor = try fixture.budget.inspect(allocator);
    defer after_successor.deinit();
    const added_total = after_successor.used.logical_total - after_retry.used.logical_total;
    const added_metadata = after_successor.used.metadata - after_retry.used.metadata;
    try std.testing.expectEqual(added_total, added_metadata);
    try std.testing.expect(added_metadata >= successor.manifest.len);
    try exerciseCustodyPublication(&fixture, captured.identity, plans);
    try exerciseBundleReadback(&fixture, captured);
    try fixture.target.revalidate(fixture.path);
}

fn exerciseCustodyPublication(
    fixture: *BundleTargetFixture,
    identity: []const u8,
    plans: *const PlainPlans,
) !void {
    const allocator = std.testing.allocator;
    const options: storage_admission.ApplyOptions = .{
        .publication = fixture.publicationOptions(),
    };
    try interruptAdmissionStaging(fixture, identity, plans, options);
    var applied = try storage_admission.applyPublished(
        allocator,
        &fixture.target,
        identity,
        &plans.parameters,
        options,
    );
    defer applied.deinit(allocator);
    try std.testing.expectEqual(.committed, applied.receipt.semantic);
    try std.testing.expectEqual(null, applied.receipt.accounting_error);
    try std.testing.expectEqual(null, applied.verification_error);
    var scope = fixture.target.scope().?;
    try expectPlainProjection(&scope, plans, ".");
    var retried = try storage_admission.applyPublished(
        allocator,
        &fixture.target,
        identity,
        &plans.parameters,
        options,
    );
    defer retried.deinit(allocator);
    try std.testing.expect(retried.receipt.reused);
    try std.testing.expectEqual(null, retried.verification_error);
    try std.testing.expectEqualStrings(
        applied.receipt.transaction.transaction_id,
        retried.receipt.transaction.transaction_id,
    );
    try appendPlainEvent(&scope, plans, ".");
    try exerciseBudgetPreparation(fixture, plans);
}

fn budgetPreparationOptions(fixture: *BundleTargetFixture) storage_preparation.LoadOptions {
    return .{
        .max_snapshot_bytes = 1024 * 1024,
        .budget = .{
            .budget = &fixture.budget,
            .budget_id = "bundle-budget",
            .store_id = "managed-target",
        },
    };
}

test "preparation rejects a budget context for another managed store before coordination" {
    const allocator = std.testing.allocator;
    var plans = try compilePlainPlans();
    defer plans.deinit();
    var fixture = try BundleTargetFixture.init();
    defer fixture.deinit();
    var options = budgetPreparationOptions(&fixture);
    options.budget.?.store_id = "different-store";
    var mutated = false;
    try std.testing.expectError(
        error.PreparationBudgetStoreMismatch,
        storage_preparation.DeclaredSnapshot.loadForApplyWithContext(
            allocator,
            &fixture.target,
            &plans.artifact,
            &plans.store,
            &plans.parameters,
            options,
            &mutated,
        ),
    );
    try std.testing.expect(!mutated);
    try std.testing.expectError(error.FileNotFound, fixture.target.openControlFile(
        ".transactions/.recovery.advisory",
    ));
}

fn exerciseBudgetPreparation(fixture: *BundleTargetFixture, plans: *const PlainPlans) !void {
    const allocator = std.testing.allocator;
    try expectBudgetContextRequired(fixture, plans);
    var selected = try storage_preparation.DeclaredSnapshot.loadWithContext(
        allocator,
        &fixture.target,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        budgetPreparationOptions(fixture),
    );
    defer selected.deinit(allocator);
    try std.testing.expect(selected.coordinated());
    try std.testing.expectEqual(.supplied_budget_store, selected.recoveryCoverage());
    var captured = try storage_bundle.captureDeclared(allocator, &selected, .{
        .closure = &plans.closure,
        .entry_path = "plain.json",
        .target = .{ .store_id = "managed-target", .generation = "recapture" },
        .limits = .{ .payload_bytes = 1024 * 1024 },
    });
    defer captured.deinit();
    var terminal_seen = false;
    var association_seen = false;
    var selected_seen = false;
    for (captured.files) |file| {
        if (std.mem.startsWith(u8, file.descriptor.path, ".evidence/") and
            std.mem.indexOf(u8, file.content, "durable-reservation-terminal/v1") != null)
        {
            terminal_seen = true;
        }
        if (std.mem.startsWith(u8, file.descriptor.path, ".evidence/") and
            std.mem.indexOf(u8, file.content, "durable-transaction-budget/v1") != null)
        {
            association_seen = true;
        }
        if (std.mem.eql(u8, file.descriptor.path, "example/plain.jsonl")) {
            selected_seen = true;
            try std.testing.expectEqualStrings(selected.slots[0].content, file.content);
        }
    }
    try std.testing.expect(terminal_seen);
    try std.testing.expect(association_seen);
    try std.testing.expect(selected_seen);
    var candidate = try storage_admission.prepare(allocator, &captured, &plans.parameters, .{
        .limits = .{ .payload_bytes = 1024 * 1024 },
    });
    defer candidate.deinit();
    try std.testing.expect(candidate.records_validated > 0);
    for (candidate.files) |file| {
        try std.testing.expect(!std.mem.startsWith(u8, file.path, ".evidence/"));
        try std.testing.expect(!std.mem.startsWith(u8, file.path, ".transactions/"));
    }
    try expectStableBudgetPreparation(fixture, plans, captured.identity);
    try expectExplicitBudgetPreparation(fixture, plans);
}

fn expectExplicitBudgetPreparation(fixture: *BundleTargetFixture, plans: *const PlainPlans) !void {
    const allocator = std.testing.allocator;
    var evidence = try BundleObservationFixture.init(fixture.path);
    defer evidence.deinit();
    var admitted = try evidence.admit(&fixture.target);
    defer admitted.deinit();
    const encoded = try storage_sources.encode(allocator, &.{admitted.descriptor()}, .{});
    defer allocator.free(encoded);
    var options = explicitSourceOptions(plans);
    try std.testing.expectError(
        error.PreparationBudgetContextRequired,
        storage_preparation_sources.Declared.open(
            allocator,
            std.testing.io,
            encoded,
            &plans.parameters,
            options,
        ),
    );
    options.budgets = &.{.{
        .source_id = admitted.descriptor().source_id,
        .context = budgetPreparationOptions(fixture).budget.?,
    }};
    var held = try storage_preparation_sources.Declared.open(
        allocator,
        std.testing.io,
        encoded,
        &plans.parameters,
        options,
    );
    defer held.deinit();
    var candidate = try storage_admission.prepare(allocator, &held.captured, &plans.parameters, .{
        .limits = options.limits.bundle,
    });
    defer candidate.deinit();
    try std.testing.expect(candidate.records_validated > 0);
    options.budgets = &.{.{
        .source_id = "unknown-source",
        .context = budgetPreparationOptions(fixture).budget.?,
    }};
    try std.testing.expectError(
        error.InvalidPreparationBudgetContext,
        storage_preparation_sources.Declared.open(
            allocator,
            std.testing.io,
            encoded,
            &plans.parameters,
            options,
        ),
    );
}

fn expectBudgetContextRequired(fixture: *BundleTargetFixture, plans: *const PlainPlans) !void {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.PreparationBudgetContextRequired,
        storage_preparation.DeclaredSnapshot.load(
            allocator,
            &fixture.target,
            &plans.artifact,
            &plans.store,
            &plans.parameters,
            1024 * 1024,
        ),
    );
    var foreign = try BundleTargetFixture.init();
    defer foreign.deinit();
    var before = try foreign.budget.inspect(allocator);
    defer before.deinit();
    var options = budgetPreparationOptions(fixture);
    options.budget.?.budget = &foreign.budget;
    try std.testing.expectError(
        error.TransactionDependencyBudgetMismatch,
        storage_preparation.DeclaredSnapshot.loadWithContext(
            allocator,
            &fixture.target,
            &plans.artifact,
            &plans.store,
            &plans.parameters,
            options,
        ),
    );
    var after = try foreign.budget.inspect(allocator);
    defer after.deinit();
    try std.testing.expectEqual(before.parsed.value.generation, after.parsed.value.generation);
}

fn expectStableBudgetPreparation(
    fixture: *BundleTargetFixture,
    plans: *const PlainPlans,
    expected_identity: []const u8,
) !void {
    const allocator = std.testing.allocator;
    _ = try fixture.budget.reserve(allocator, .{
        .budget_id = "bundle-budget",
        .store_id = "managed-target",
        .operation_id = "unrelated-read-capture",
        .charge = .zero,
    }, BundleTargetFixture.freeObservation());
    var selected = try storage_preparation.DeclaredSnapshot.loadWithContext(
        allocator,
        &fixture.target,
        &plans.artifact,
        &plans.store,
        &plans.parameters,
        budgetPreparationOptions(fixture),
    );
    defer selected.deinit(allocator);
    var captured = try storage_bundle.captureDeclared(allocator, &selected, .{
        .closure = &plans.closure,
        .entry_path = "plain.json",
        .target = .{ .store_id = "managed-target", .generation = "recapture" },
        .limits = .{ .payload_bytes = 1024 * 1024 },
    });
    defer captured.deinit();
    try std.testing.expectEqualStrings(expected_identity, captured.identity);
}

fn interruptAdmissionStaging(
    fixture: *BundleTargetFixture,
    identity: []const u8,
    plans: *const PlainPlans,
    options: storage_admission.ApplyOptions,
) !void {
    PublicationStageFault.stage_handle = null;
    var table = std.testing.io.vtable.*;
    table.dirCreateFile = PublicationStageFault.create;
    table.fileSync = PublicationStageFault.sync;
    fixture.target.io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    defer fixture.target.io = std.testing.io;
    var interrupted = try storage_admission.applyPublished(
        std.testing.allocator,
        &fixture.target,
        identity,
        &plans.parameters,
        options,
    );
    defer interrupted.deinit(std.testing.allocator);
    try std.testing.expectEqual(.recovery_required, interrupted.receipt.semantic);
    try std.testing.expectEqual(error.InputOutput, interrupted.receipt.failure.?);
    var coordination_mutated = false;
    try std.testing.expectError(
        error.PreparationSourceRecoveryRequired,
        storage_preparation.DeclaredSnapshot.loadForApplyWithContext(
            std.testing.allocator,
            &fixture.target,
            &plans.artifact,
            &plans.store,
            &plans.parameters,
            budgetPreparationOptions(fixture),
            &coordination_mutated,
        ),
    );
}

const PublicationStageFault = struct {
    var stage_handle: ?@FieldType(std.Io.File, "handle") = null;

    fn create(
        userdata: ?*anyopaque,
        directory: std.Io.Dir,
        name: []const u8,
        options: std.Io.Dir.CreateFileOptions,
    ) std.Io.File.OpenError!std.Io.File {
        const file = try std.testing.io.vtable.dirCreateFile(
            userdata,
            directory,
            name,
            options,
        );
        if (std.mem.startsWith(u8, name, ".ledger-dtx-stage-")) stage_handle = file.handle;
        return file;
    }

    fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        if (stage_handle != null and file.handle == stage_handle.?) {
            stage_handle = null;
            return error.InputOutput;
        }
        return std.testing.io.vtable.fileSync(userdata, file);
    }
};

fn interruptBundleStaging(
    fixture: *BundleTargetFixture,
    captured: *const storage_bundle.Captured,
) !void {
    PublicationStageFault.stage_handle = null;
    var table = std.testing.io.vtable.*;
    table.dirCreateFile = PublicationStageFault.create;
    table.fileSync = PublicationStageFault.sync;
    fixture.target.io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    defer fixture.target.io = std.testing.io;
    var interrupted = try fixture.publish(captured);
    defer interrupted.deinit(std.testing.allocator);
    try std.testing.expectEqual(.recovery_required, interrupted.receipt.semantic);
    try std.testing.expectEqual(error.InputOutput, interrupted.receipt.failure.?);
}

fn exerciseBundleReadback(
    fixture: *BundleTargetFixture,
    captured: *const storage_bundle.Captured,
) !void {
    const allocator = std.testing.allocator;
    const limits: storage_bundle.Limits = .{
        .payload_bytes = 1024 * 1024,
        .manifest_bytes = 64 * 1024,
    };
    var readback = try storage_bundle.loadPublished(
        allocator,
        &fixture.target,
        captured.identity,
        limits,
    );
    defer readback.deinit();
    try std.testing.expectEqualStrings(captured.identity, readback.identity);
    try std.testing.expectEqualStrings(captured.manifest, readback.manifest);
    try std.testing.expectEqual(captured.payload_bytes, readback.payload_bytes);
    try std.testing.expectEqual(captured.files.len, readback.files.len);
    for (readback.files) |actual| {
        var found = false;
        for (captured.files) |expected| {
            if (!std.mem.eql(u8, actual.descriptor.path, expected.descriptor.path)) continue;
            try std.testing.expectEqualStrings(expected.content, actual.content);
            found = true;
        }
        try std.testing.expect(found);
    }
    var retry = try fixture.publish(&readback);
    defer retry.deinit(allocator);
    try std.testing.expect(retry.receipt.reused);
    try std.testing.expectEqual(null, retry.verification_error);
    const file = readback.files[0];
    try std.testing.expect(file.content.len > 0);
    const path = try allocator.print(
        ".ledger/.preservation/objects/{s}",
        .{file.descriptor.content_id[7..]},
    );
    defer allocator.free(path);
    const tampered = try allocator.dupe(u8, file.content);
    defer allocator.free(tampered);
    tampered[0] ^= 1;
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = tampered });
    try std.testing.expectError(error.BundleContentMismatch, storage_bundle.loadPublished(
        allocator,
        &fixture.target,
        captured.identity,
        limits,
    ));
    var damaged_retry = try fixture.publish(&readback);
    defer damaged_retry.deinit(allocator);
    try std.testing.expectEqual(.committed, damaged_retry.receipt.semantic);
    try std.testing.expect(damaged_retry.receipt.reused);
    try std.testing.expectEqual(error.BundleContentMismatch, damaged_retry.verification_error.?);
    try fixture.tmp.dir.deleteFile(std.testing.io, path);
    try std.testing.expectError(error.FileNotFound, storage_bundle.loadPublished(
        allocator,
        &fixture.target,
        captured.identity,
        limits,
    ));
}
