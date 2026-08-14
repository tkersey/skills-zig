const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");

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
pub const state_reducer = @import("state_reducer.zig");
pub const segmented_event_log = @import("segmented_event_log.zig");
pub const doctor = @import("doctor.zig");
pub const migration = @import("migration.zig");
pub const envelope = @import("envelope.zig");
pub const checkpoint = @import("checkpoint.zig");

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
    _ = state_reducer;
    _ = segmented_event_log;
    _ = doctor;
    _ = migration;
    _ = envelope;
    _ = checkpoint;
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
    var definition_tmp = std.testing.tmpDir(.{});
    defer definition_tmp.cleanup();
    try definition_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "plain.json",
        .data = @embedFile("fixtures/plain-event-definition.json"),
    });
    var closure = try definition_core.closure.loadFromDir(
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

fn bindPlainStore(plans: *const PlainPlans, repo_root: []const u8) !void {
    var binding = try transaction.transact(
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

fn appendPlainEvent(plans: *const PlainPlans, repo_root: []const u8) !void {
    var appended = try transaction.transact(
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
    plans: *const PlainPlans,
    repo_root: []const u8,
) !void {
    var appended = try transaction.transact(
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
    plans: *const PlainPlans,
    repo_root: []const u8,
    id: []const u8,
) !void {
    const bytes = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"kind\":\"created\",\"value\":{{" ++
            "\"id\":\"{s}\",\"revision\":1}}}}",
        .{id},
    );
    defer std.testing.allocator.free(bytes);
    var appended = try transaction.transact(
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

fn expectPlainProjection(plans: *const PlainPlans, repo_root: []const u8) !void {
    var result = try projection.execute(
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
        "[{\"current\":{\"id\":\"item-1\",\"revision\":1}," ++
            "\"event_count\":2,\"id\":\"item-1\",\"status\":\"current\"}]",
        result.payload,
    );
}

test "plain protocol binds appends replays and folds without rewriting history" {
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
    try bindPlainStore(&plans, repo_root);
    const after_binding = try repo_tmp.dir.readFileAlloc(
        std.testing.io,
        ".ledger/example/plain.jsonl",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(after_binding);
    try std.testing.expectEqualStrings(original, after_binding);
    try appendPlainEvent(&plans, repo_root);
    try expectPlainProjection(&plans, repo_root);
}

test "segmented bind existing bootstraps explicit migration" {
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
    try bindPlainStore(&plans, repo_root);
    var migrated = try migration.execute(
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
    try appendPlainEvent(&plans, repo_root);
    try expectPlainProjection(&plans, repo_root);
}

test "segmented migration preserves legacy jsonl framing" {
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
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    try bindPlainStore(&plans, repo_root);
    const legacy_revision = try definition_core.canonical_json.digestBytesAlloc(
        std.testing.allocator,
        legacy,
    );
    defer std.testing.allocator.free(legacy_revision);
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    var migrated = try migration.execute(
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
    var before_append = try segmented_event_log.Snapshot.load(
        std.testing.allocator,
        repo_root,
        "example/plain.jsonl",
    );
    try std.testing.expect(before_append.head.event_separator_pending);
    try segmented_event_log.auditHistory(
        std.testing.allocator,
        &before_append,
    );
    before_append.deinit(std.testing.allocator);
    try appendPlainEvent(&plans, repo_root);
    var after_append = try segmented_event_log.Snapshot.load(
        std.testing.allocator,
        repo_root,
        "example/plain.jsonl",
    );
    defer after_append.deinit(std.testing.allocator);
    try std.testing.expect(!after_append.head.event_separator_pending);
    try std.testing.expect(after_append.event_bytes.len != 0);
    try std.testing.expectEqual(@as(u8, '\n'), after_append.event_bytes[0]);
    var health = try doctor.execute(
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
    try appendPlainCreatedEvent(&plans, repo_root);
    plans.artifact.bounds.max_records = 1;
    try appendPlainEvent(&plans, repo_root);
    var snapshot = try segmented_event_log.Snapshot.load(
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
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = future_path,
        .data = "{}\n",
    });
    try std.testing.expectError(
        error.UnexpectedFutureSegment,
        segmented_event_log.auditHistory(std.testing.allocator, &snapshot),
    );
}

test "segmented checkpoint enforces keyed reducer retained bounds" {
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
    try appendPlainCreatedEvent(&plans, repo_root);
    try appendPlainCreatedEventFor(&plans, repo_root, "item-2");
    plans.artifact.bounds.max_records = 2;
    plans.protocol.reducer_plan.?.max_retained_value_bytes = 1;
    plans.protocol.reducer_plan.?.max_retained_total_bytes = 1;
    try std.testing.expectError(
        error.CheckpointBoundsExceeded,
        transaction.transact(
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
    try appendPlainCreatedEvent(&plans, repo_root);
    try appendPlainEvent(&plans, repo_root);
    plans.artifact.bounds.max_records = 1;
    plans.protocol.max_records = 1;
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    var migrated = try migration.execute(
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
    const history_projection = &plans.projection.projections[0];
    const fold = history_projection.fold;
    history_projection.fold = null;
    defer history_projection.fold = fold;
    var missing = try projection.execute(
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
    try appendPlainCreatedEvent(&plans, repo_root);
    var genesis_doctor = try doctor.execute(
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
    for (0..4) |_| try appendPlainEvent(&plans, repo_root);
    var lifetime_doctor = try doctor.execute(
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
    try appendPlainCreatedEvent(&plans, repo_root);
    var snapshot = try segmented_event_log.Snapshot.load(
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
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data = head_bytes,
    });
    try std.testing.expectError(
        error.SegmentedProjectionCheckpointMissing,
        projection.execute(
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
    try bindPlainStore(&plans, repo_root);
    try appendPlainEvent(&plans, repo_root);
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
        std.testing.allocator,
        repo_root,
        "example/plain.jsonl",
    );
    defer std.testing.allocator.free(binding_path);
    const legacy_binding = try durable_store.readRegularFileNoSymlink(
        std.testing.allocator,
        binding_path,
        1024 * 1024,
    );
    defer std.testing.allocator.free(legacy_binding);
    plans.store.slots[0].layout = .segmented;
    plans.store.slots[0].max_bytes = segmented_event_log.event_segment_bytes;
    try std.testing.expectError(
        error.SegmentedMigrationRequired,
        projection.execute(
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
    var migrated = try migration.execute(
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
        std.testing.allocator,
        repo_root,
        "example/plain.jsonl",
    );
    defer segmented.deinit(std.testing.allocator);
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
        std.testing.allocator,
        sealed_binding_path,
        segmented_event_log.binding_segment_bytes,
    );
    defer std.testing.allocator.free(sealed_bindings);
    try std.testing.expectEqualStrings(legacy_binding, sealed_bindings);
    try expectPlainProjection(&plans, repo_root);
    const post_migration_projection = &plans.projection.projections[0];
    const post_migration_fold = post_migration_projection.fold;
    post_migration_projection.fold = null;
    var raw_projection = try projection.execute(
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
        std.testing.allocator,
        &plans.artifact,
        &plans.store,
        &plans.protocol,
        repo_root,
        &plans.parameters,
    );
    defer post_migration_doctor.deinit(std.testing.allocator);
    try std.testing.expect(post_migration_doctor.healthy);
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
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = segmented.checkpoint_path.?,
        .data = invalid_checkpoint,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = segmented.paths.manifest,
        .data = invalid_head_bytes,
    });
    try std.Io.Dir.cwd().deleteFile(
        std.testing.io,
        segmented.paths.legacy_event,
    );
    try std.Io.Dir.cwd().deleteFile(
        std.testing.io,
        segmented.paths.legacy_binding,
    );
    try std.testing.expectError(
        error.SegmentedCheckpointStateMismatch,
        migration.execute(
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
        std.Io.Dir.cwd().statFile(
            std.testing.io,
            segmented.paths.legacy_event,
            .{},
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(
            std.testing.io,
            segmented.paths.legacy_binding,
            .{},
        ),
    );
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = segmented.paths.legacy_event,
        .data = segmented_event_log.legacy_event_tombstone,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = segmented.paths.legacy_binding,
        .data = segmented_event_log.legacy_binding_tombstone,
    });
    const checkpoint_projection = &plans.projection.projections[0];
    const checkpoint_fold = checkpoint_projection.fold;
    checkpoint_projection.fold = null;
    try std.testing.expectError(
        error.SegmentedCheckpointStateMismatch,
        expectPlainProjection(&plans, repo_root),
    );
    checkpoint_projection.fold = checkpoint_fold;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = segmented.checkpoint_path.?,
        .data = segmented.checkpoint_bytes,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = segmented.paths.manifest,
        .data = segmented.head_bytes,
    });
    try std.Io.Dir.cwd().deleteFile(
        std.testing.io,
        segmented.paths.legacy_event,
    );
    try std.Io.Dir.cwd().deleteFile(
        std.testing.io,
        segmented.paths.legacy_binding,
    );
    var reconciled = try migration.execute(
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
    const archive_path = try definition_archive.pathAlloc(
        std.testing.allocator,
        repo_root,
        &plans.artifact.closure_digest,
    );
    defer std.testing.allocator.free(archive_path);
    const archive_bytes = try durable_store.readRegularFileNoSymlink(
        std.testing.allocator,
        archive_path,
        definition_archive.max_bytes,
    );
    defer std.testing.allocator.free(archive_bytes);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, archive_path);
    const history_projection = &plans.projection.projections[0];
    const fold = history_projection.fold;
    history_projection.fold = null;
    defer history_projection.fold = fold;
    try std.testing.expectError(
        error.HistoricalDefinitionMissing,
        expectPlainProjection(&plans, repo_root),
    );
    history_projection.fold = fold;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = archive_path,
        .data = archive_bytes,
    });
    var repeated = try migration.execute(
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
