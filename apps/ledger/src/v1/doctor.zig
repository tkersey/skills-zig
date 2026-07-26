const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const protocol = @import("protocol.zig");
const replay = @import("replay.zig");
const storage = @import("storage.zig");

pub const SlotStatus = struct {
    name: []u8,
    logical_ref: []u8,
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
        ) catch |err| try unhealthySlot(allocator, slot, err);
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

fn inspectSlot(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    repo_root: []const u8,
    slot: storage.ResolvedSlot,
    parameters: *const definition_core.parameters.Bindings,
    protocol_required: bool,
) !SlotStatus {
    var snapshot = try custody.readSlot(
        allocator,
        repo_root,
        definition_plan.id,
        slot,
    );
    defer snapshot.deinit(allocator);
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
        .revision = revision,
        .binding_rows = snapshot.binding.rows.len,
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
        .revision = null,
        .binding_rows = 0,
        .healthy = false,
        .error_code = error_code,
    };
}
