const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const protocol = @import("protocol.zig");
const replay = @import("replay.zig");
const storage = @import("storage.zig");

pub const SlotState = enum {
    missing,
    current,
    invalid,

    pub fn id(self: SlotState) []const u8 {
        return @tagName(self);
    }
};

pub const SlotStatus = struct {
    name: []u8,
    logical_ref: []u8,
    state: SlotState,
    revision: ?[]u8,
    binding_rows: usize,
    healthy: bool,
    error_code: ?[]u8,

    fn deinit(self: *SlotStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.logical_ref);
        if (self.revision) |revision| allocator.free(revision);
        if (self.error_code) |code| allocator.free(code);
        self.* = undefined;
    }
};

pub const Result = struct {
    definition_id: []u8,
    definition_digest: [71]u8,
    pending_transactions: usize,
    slots: []SlotStatus,
    healthy: bool,
    authority_granted: bool = false,
    storage_mutated: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.definition_id);
        for (self.slots) |*slot| slot.deinit(allocator);
        allocator.free(self.slots);
        self.* = undefined;
    }
};

pub fn execute(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    if (!std.fs.path.isAbsolute(repo_root)) return error.RepositoryRootNotAbsolute;
    const transactions_dir = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", ".transactions" },
    );
    defer allocator.free(transactions_dir);
    const pending_transactions = try durable_store.countPendingTransactions(
        allocator,
        transactions_dir,
    );
    var resolved_storage = try storage.resolve(
        allocator,
        storage_plan,
        parameters,
    );
    defer resolved_storage.deinit(allocator);
    const slots = try allocator.alloc(
        SlotStatus,
        resolved_storage.slotSlice().len,
    );
    var initialized: usize = 0;
    errdefer {
        for (slots[0..initialized]) |*slot| slot.deinit(allocator);
        allocator.free(slots);
    }
    var healthy = pending_transactions == 0;
    for (resolved_storage.slotSlice(), 0..) |slot, index| {
        slots[index] = inspectSlot(
            allocator,
            definition_plan,
            repo_root,
            slot,
            parameters,
            event_protocol != null and
                event_protocol.?.target_slot_index == index,
        ) catch |err| try classifySlotError(allocator, slot, err);
        initialized += 1;
        if (!slots[index].healthy) healthy = false;
    }
    return .{
        .definition_id = try allocator.dupe(u8, definition_plan.id),
        .definition_digest = definition_plan.closure_digest,
        .pending_transactions = pending_transactions,
        .slots = slots,
        .healthy = healthy,
    };
}

fn classifySlotError(
    allocator: std.mem.Allocator,
    slot: storage.ResolvedSlot,
    err: anyerror,
) !SlotStatus {
    return if (err == error.StoreSlotMissing)
        missingSlot(allocator, slot)
    else
        unhealthySlot(allocator, slot, err);
}

fn inspectSlot(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    repo_root: []const u8,
    slot: storage.ResolvedSlot,
    parameters: *const definition_core.parameters.Bindings,
    protocol_required: bool,
) !SlotStatus {
    var snapshot = try custody.readSlotOrMissing(
        allocator,
        repo_root,
        definition_plan.id,
        slot,
    );
    defer snapshot.deinit(allocator);
    if (!snapshot.exists) return error.StoreSlotMissing;
    var replay_stats = try replay.validateSlot(
        allocator,
        repo_root,
        definition_plan.id,
        slot,
        &snapshot,
        parameters,
        definition_plan.bounds.max_records,
        protocol_required,
    );
    defer replay_stats.deinit(allocator);
    const name = try allocator.dupe(u8, slot.name);
    errdefer allocator.free(name);
    const logical_ref = try allocator.dupe(u8, slot.relative_path);
    errdefer allocator.free(logical_ref);
    const revision = try allocator.dupe(u8, snapshot.revision);
    return .{
        .name = name,
        .logical_ref = logical_ref,
        .state = .current,
        .revision = revision,
        .binding_rows = snapshot.binding.rows.len,
        .healthy = true,
        .error_code = null,
    };
}

fn missingSlot(
    allocator: std.mem.Allocator,
    slot: storage.ResolvedSlot,
) !SlotStatus {
    const name = try allocator.dupe(u8, slot.name);
    errdefer allocator.free(name);
    const logical_ref = try allocator.dupe(u8, slot.relative_path);
    return .{
        .name = name,
        .logical_ref = logical_ref,
        .state = .missing,
        .revision = null,
        .binding_rows = 0,
        .healthy = true,
        .error_code = null,
    };
}

fn unhealthySlot(
    allocator: std.mem.Allocator,
    slot: storage.ResolvedSlot,
    err: anyerror,
) !SlotStatus {
    const name = try allocator.dupe(u8, slot.name);
    errdefer allocator.free(name);
    const logical_ref = try allocator.dupe(u8, slot.relative_path);
    errdefer allocator.free(logical_ref);
    const error_code = try allocator.dupe(u8, @errorName(err));
    return .{
        .name = name,
        .logical_ref = logical_ref,
        .state = .invalid,
        .revision = null,
        .binding_rows = 0,
        .healthy = false,
        .error_code = error_code,
    };
}

const doctor_definition_json =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/doctor","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":[]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/events.jsonl","kind":"event-log","codec":"jsonl","max_bytes":4096}}},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":4096,"max_records":10,"max_output_bytes":1024,"max_diagnostics":8,"max_reducer_states":1}}
;

test "missing declared storage is a healthy initial state" {
    var definition_tmp = std.testing.tmpDir(.{});
    defer definition_tmp.cleanup();
    try definition_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data = doctor_definition_json,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &definition_tmp.dir,
        "protocol.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "protocol.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var storage_plan = try storage.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer storage_plan.deinit(std.testing.allocator);
    var parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{},
    );
    defer parameters.deinit(std.testing.allocator);
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    var result = try execute(
        std.testing.allocator,
        &definition_plan,
        &storage_plan,
        null,
        repo_root,
        &parameters,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.healthy);
    try std.testing.expectEqual(@as(usize, 1), result.slots.len);
    try std.testing.expectEqual(SlotState.missing, result.slots[0].state);
    try std.testing.expect(result.slots[0].healthy);
    try std.testing.expect(result.slots[0].revision == null);
    try std.testing.expect(result.slots[0].error_code == null);
}

test "missing replay dependencies remain unhealthy" {
    const slot = storage.ResolvedSlot{
        .name = "events",
        .relative_path = "example/events.jsonl",
        .owned_path = null,
        .kind = .event_log,
        .codec = .jsonl,
        .max_bytes = 4096,
    };
    var result = try classifySlotError(
        std.testing.allocator,
        slot,
        error.FileNotFound,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(SlotState.invalid, result.state);
    try std.testing.expect(!result.healthy);
    try std.testing.expectEqualStrings("FileNotFound", result.error_code.?);
}
