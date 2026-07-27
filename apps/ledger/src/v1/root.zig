const std = @import("std");
const definition_core = @import("definition_core");

pub const definition = @import("definition.zig");
pub const compiled_plan = @import("compiled_plan.zig");
pub const revision_archive = @import("revision_archive.zig");
pub const validation = @import("validation.zig");
pub const materialization = @import("materialization.zig");
pub const storage = @import("storage.zig");
pub const definition_archive = @import("definition_archive.zig");
pub const custody = @import("custody.zig");
pub const transaction = @import("transaction.zig");
pub const projection = @import("projection.zig");
pub const replay = @import("replay.zig");
pub const protocol = @import("protocol.zig");
pub const reducer = @import("reducer.zig");
pub const state_reducer = @import("state_reducer.zig");
pub const doctor = @import("doctor.zig");
pub const envelope = @import("envelope.zig");

test {
    _ = definition;
    _ = compiled_plan;
    _ = revision_archive;
    _ = validation;
    _ = materialization;
    _ = storage;
    _ = definition_archive;
    _ = custody;
    _ = transaction;
    _ = projection;
    _ = replay;
    _ = protocol;
    _ = reducer;
    _ = state_reducer;
    _ = doctor;
    _ = envelope;
}

test "plain protocol binds appends replays and folds without rewriting history" {
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
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "plain.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var validation_plan = try validation.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer validation_plan.deinit(std.testing.allocator);
    var storage_plan = try storage.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer storage_plan.deinit(std.testing.allocator);
    var compiled_protocol = (try protocol.compile(
        std.testing.allocator,
        &definition_plan,
        &storage_plan,
    )).?;
    defer compiled_protocol.deinit(std.testing.allocator);
    var protocol_encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer protocol_encoder.deinit();
    try protocol.encodeCache(&compiled_protocol, &protocol_encoder);
    const protocol_payload = try protocol_encoder.toOwnedSlice();
    defer std.testing.allocator.free(protocol_payload);
    var protocol_decoder =
        definition_core.cache.Decoder.init(protocol_payload);
    var protocol_plan = try protocol.decodeCache(
        std.testing.allocator,
        &protocol_decoder,
    );
    defer protocol_plan.deinit(std.testing.allocator);
    try protocol_decoder.finish();
    try protocol.validateCachePlan(
        &protocol_plan,
        &definition_plan,
        &storage_plan,
    );
    try std.testing.expectEqual(protocol.Mode.plain, protocol_plan.mode);
    try std.testing.expect(protocol_plan.reducer_plan != null);
    try std.testing.expect(protocol_plan.state_reducer_plan == null);
    var projection_plan = try projection.compile(
        std.testing.allocator,
        &definition_plan,
        &storage_plan,
        &protocol_plan,
    );
    defer projection_plan.deinit(std.testing.allocator);
    var parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{},
    );
    defer parameters.deinit(std.testing.allocator);

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

    var binding = try transaction.transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "plain.json",
        &validation_plan,
        &storage_plan,
        &protocol_plan,
        "bind-existing",
        repo_root,
        &.{},
        &parameters,
    );
    defer binding.deinit(std.testing.allocator);
    try std.testing.expect(binding.storage_mutated);
    const after_binding = try repo_tmp.dir.readFileAlloc(
        std.testing.io,
        ".ledger/example/plain.jsonl",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(after_binding);
    try std.testing.expectEqualStrings(original, after_binding);

    var appended = try transaction.transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "plain.json",
        &validation_plan,
        &storage_plan,
        &protocol_plan,
        "append",
        repo_root,
        &.{.{
            .name = "event",
            .bytes = "{\"kind\":\"updated\",\"value\":{\"id\":\"item-1\",\"revision\":2}}",
        }},
        &parameters,
    );
    defer appended.deinit(std.testing.allocator);
    try std.testing.expect(appended.storage_mutated);

    var result = try projection.execute(
        std.testing.allocator,
        &definition_plan,
        &storage_plan,
        &protocol_plan,
        &projection_plan,
        "current",
        repo_root,
        &parameters,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "[{\"id\":\"item-1\",\"status\":\"current\"}]",
        result.payload,
    );
}
