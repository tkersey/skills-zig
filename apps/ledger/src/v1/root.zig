const std = @import("std");
const definition_core = @import("definition_core");

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
pub const doctor = @import("doctor.zig");
pub const envelope = @import("envelope.zig");

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
    _ = doctor;
    _ = envelope;
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
