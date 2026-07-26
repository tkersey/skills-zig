const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const definition = @import("definition.zig");
const materialization = @import("materialization.zig");
const storage = @import("storage.zig");
const validation = @import("validation.zig");

const BindingMaxBytes = 16 * 1024 * 1024;

pub const EffectReceipt = struct {
    slot: []u8,
    logical_ref: []u8,
    revision_before: ?[]u8,
    revision_after: []u8,
    result: []u8,

    fn deinit(self: *EffectReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.slot);
        allocator.free(self.logical_ref);
        if (self.revision_before) |revision| allocator.free(revision);
        allocator.free(self.revision_after);
        allocator.free(self.result);
        self.* = undefined;
    }
};

pub const Result = struct {
    validation_result: validation.Result,
    operation: []u8,
    transaction_id: ?[]u8,
    effects: []EffectReceipt,
    returned_content: ?[]u8,
    semantic_authority_granted: bool = false,
    storage_mutated: bool,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.validation_result.deinit(allocator);
        allocator.free(self.operation);
        if (self.transaction_id) |transaction_id| allocator.free(transaction_id);
        for (self.effects) |*effect| effect.deinit(allocator);
        allocator.free(self.effects);
        if (self.returned_content) |content| allocator.free(content);
        self.* = undefined;
    }
};

const BindingSnapshot = struct {
    exists: bool,
    bytes: []u8,
    digest: ?[]u8,
    last_revision: ?[]u8,
    idempotency_match: bool,

    fn deinit(self: *BindingSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        if (self.digest) |digest| allocator.free(digest);
        if (self.last_revision) |revision| allocator.free(revision);
        self.* = undefined;
    }
};

const PreparedEffect = struct {
    slot_index: u16,
    kind: storage.EffectKind,
    slot_path: []u8,
    binding_path: []u8,
    slot_before: ?[]u8,
    slot_before_digest: ?[]u8,
    slot_after: []u8,
    slot_after_digest: []u8,
    binding_before: BindingSnapshot,
    binding_after: []u8,
    canonical_input: []u8,
    idempotency_match: bool,

    fn deinit(self: *PreparedEffect, allocator: std.mem.Allocator) void {
        allocator.free(self.slot_path);
        allocator.free(self.binding_path);
        if (self.slot_before) |bytes| allocator.free(bytes);
        if (self.slot_before_digest) |digest| allocator.free(digest);
        allocator.free(self.slot_after);
        allocator.free(self.slot_after_digest);
        self.binding_before.deinit(allocator);
        allocator.free(self.binding_after);
        allocator.free(self.canonical_input);
        self.* = undefined;
    }
};

pub fn installRuntimeIo(io: std.Io) void {
    durable_store.installRuntimeIo(io);
}

pub fn transact(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    validation_plan: *const validation.Plan,
    storage_plan: *const storage.Plan,
    operation_name: []const u8,
    repo_root: []const u8,
    documents: []const validation.InputDocument,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    if (!std.fs.path.isAbsolute(repo_root)) return error.RepositoryRootNotAbsolute;
    const operation = storage_plan.findOperation(operation_name) orelse
        return error.UnknownOperation;
    var execution = try validation.execute(allocator, validation_plan, documents);
    defer execution.deinit();
    if (!execution.isValid()) {
        const owned_operation = try allocator.dupe(u8, operation_name);
        errdefer allocator.free(owned_operation);
        const validation_result = try execution.takeResult(allocator, definition_plan);
        return .{
            .validation_result = validation_result,
            .operation = owned_operation,
            .transaction_id = null,
            .effects = try allocator.alloc(EffectReceipt, 0),
            .returned_content = null,
            .storage_mutated = false,
        };
    }

    const ledger_root = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger" },
    );
    defer allocator.free(ledger_root);
    const transactions_dir = try std.fs.path.join(
        allocator,
        &.{ ledger_root, ".transactions" },
    );
    defer allocator.free(transactions_dir);
    const bindings_dir = try std.fs.path.join(
        allocator,
        &.{ ledger_root, ".bindings" },
    );
    defer allocator.free(bindings_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(ledger_root);
    try durable_store.ensureDirectoryPathNoSymlinks(transactions_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(bindings_dir);
    try durable_store.ensureNoPendingTransactions(allocator, transactions_dir);

    const prepared = try prepareEffects(
        allocator,
        definition_plan,
        storage_plan,
        operation,
        operation_name,
        repo_root,
        &execution,
        parameters,
    );
    defer {
        for (prepared) |*effect| effect.deinit(allocator);
        allocator.free(prepared);
    }
    var duplicate_count: usize = 0;
    for (prepared) |effect| if (effect.idempotency_match) {
        duplicate_count += 1;
    };
    if (duplicate_count != 0 and duplicate_count != prepared.len) {
        return error.PartialIdempotencyMatch;
    }

    var transaction_id: ?[]u8 = null;
    var storage_mutated = false;
    if (duplicate_count == 0) {
        const mutations = try buildMutations(allocator, storage_plan, prepared);
        defer allocator.free(mutations);
        const counter_path = try std.fs.path.join(
            allocator,
            &.{ ledger_root, ".fencing.counter" },
        );
        defer allocator.free(counter_path);
        var commit = try durable_store.commitTextTransaction(
            allocator,
            transactions_dir,
            mutations,
            .{
                .owner = .{
                    .process_id = 0,
                    .session_id = "ledger-artifact-abi-v1",
                    .executor = "ledger",
                },
                .fencing_counter_path = counter_path,
                .reject_symlinks = true,
            },
        );
        defer commit.deinit(allocator);
        transaction_id = try allocator.dupe(u8, commit.transaction_id);
        storage_mutated = true;
    }
    errdefer if (transaction_id) |value| allocator.free(value);

    const receipts = try buildReceipts(
        allocator,
        storage_plan,
        prepared,
        duplicate_count != 0,
    );
    errdefer {
        for (receipts) |*receipt| receipt.deinit(allocator);
        allocator.free(receipts);
    }
    const returned_content = if (prepared.len == 1)
        try allocator.dupe(u8, prepared[0].canonical_input)
    else
        null;
    errdefer if (returned_content) |content| allocator.free(content);
    const owned_operation = try allocator.dupe(u8, operation_name);
    errdefer allocator.free(owned_operation);
    const validation_result = try execution.takeResult(allocator, definition_plan);
    return .{
        .validation_result = validation_result,
        .operation = owned_operation,
        .transaction_id = transaction_id,
        .effects = receipts,
        .returned_content = returned_content,
        .storage_mutated = storage_mutated,
    };
}

fn prepareEffects(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    operation: *const storage.Operation,
    operation_name: []const u8,
    repo_root: []const u8,
    execution: *const validation.Execution,
    parameters: *const definition_core.parameters.Bindings,
) ![]PreparedEffect {
    const prepared = try allocator.alloc(PreparedEffect, operation.effects.len);
    var initialized: usize = 0;
    errdefer {
        for (prepared[0..initialized]) |*effect| effect.deinit(allocator);
        allocator.free(prepared);
    }
    for (operation.effects, 0..) |effect, index| {
        prepared[index] = try prepareEffect(
            allocator,
            definition_plan,
            storage_plan,
            effect,
            operation_name,
            repo_root,
            execution,
            parameters,
        );
        initialized += 1;
    }
    return prepared;
}

fn prepareEffect(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    effect: storage.Effect,
    operation_name: []const u8,
    repo_root: []const u8,
    execution: *const validation.Execution,
    parameters: *const definition_core.parameters.Bindings,
) !PreparedEffect {
    const slot = storage_plan.slots[effect.slot_index];
    const slot_path = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", slot.relative_path },
    );
    errdefer allocator.free(slot_path);
    const binding_path = try bindingPathAlloc(
        allocator,
        repo_root,
        slot.relative_path,
    );
    errdefer allocator.free(binding_path);
    const slot_before = durable_store.readRegularFileNoSymlink(
        allocator,
        slot_path,
        slot.max_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    errdefer if (slot_before) |bytes| allocator.free(bytes);
    const slot_before_digest = if (slot_before) |bytes|
        try definition_core.canonical_json.digestBytesAlloc(allocator, bytes)
    else
        null;
    errdefer if (slot_before_digest) |digest| allocator.free(digest);

    switch (effect.kind) {
        .create_new => if (slot_before != null) return error.StorageSlotAlreadyExists,
        .compare_append => {},
        .compare_replace => if (slot_before == null) return error.StorageSlotMissing,
    }
    if (effect.expected_revision_parameter) |parameter_name| {
        if (parameterText(parameters, parameter_name)) |expected_revision| {
            const actual = slot_before_digest orelse return error.RevisionMismatch;
            if (!std.mem.eql(u8, actual, expected_revision)) {
                return error.RevisionMismatch;
            }
        }
    }

    const canonical_input = try materialization.canonicalizeInputAlloc(
        allocator,
        execution,
        effect.input_index,
        definition_plan.inputs[effect.input_index].codec,
    );
    errdefer allocator.free(canonical_input);
    const slot_after = try slotContentAfter(
        allocator,
        slot,
        effect.kind,
        slot_before,
        canonical_input,
    );
    errdefer allocator.free(slot_after);
    if (slot_after.len > slot.max_bytes) return error.StorageSlotBoundsExceeded;
    const slot_after_digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        slot_after,
    );
    errdefer allocator.free(slot_after_digest);
    const idempotency_key = if (effect.idempotency_parameter) |parameter_name|
        parameterText(parameters, parameter_name)
    else
        null;
    const input_digest = execution.inputDigest(
        definition_plan.inputs[effect.input_index].name,
    ) orelse return error.InputDigestMissing;
    var binding_before = try readBindingSnapshot(
        allocator,
        binding_path,
        definition_plan.id,
        slot.name,
        slot.relative_path,
        slot_before_digest,
        operation_name,
        idempotency_key,
        input_digest,
    );
    errdefer binding_before.deinit(allocator);
    if (slot_before != null and !binding_before.exists) return error.UnboundStore;
    if (slot_before == null and binding_before.exists) return error.OrphanedStoreBinding;

    const binding_after = if (binding_before.idempotency_match)
        try allocator.dupe(u8, binding_before.bytes)
    else
        try appendBindingRowAlloc(
            allocator,
            binding_before.bytes,
            definition_plan,
            slot,
            operation_name,
            input_digest,
            slot_before_digest,
            slot_after_digest,
            idempotency_key,
        );
    return .{
        .slot_index = effect.slot_index,
        .kind = effect.kind,
        .slot_path = slot_path,
        .binding_path = binding_path,
        .slot_before = slot_before,
        .slot_before_digest = slot_before_digest,
        .slot_after = slot_after,
        .slot_after_digest = slot_after_digest,
        .binding_before = binding_before,
        .binding_after = binding_after,
        .canonical_input = canonical_input,
        .idempotency_match = binding_before.idempotency_match,
    };
}

fn slotContentAfter(
    allocator: std.mem.Allocator,
    slot: storage.Slot,
    kind: storage.EffectKind,
    before: ?[]const u8,
    canonical_input: []const u8,
) ![]u8 {
    if (kind != .compare_append) return allocator.dupe(u8, canonical_input);
    if (slot.kind != .event_log) return error.AppendRequiresEventLogSlot;
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        canonical_input,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch return error.EventPayloadMustBeJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.EventPayloadMustBeObject;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (before) |bytes| {
        const jsonl_validation = durable_store.validateJsonlBytes(allocator, bytes);
        if (!jsonl_validation.ok()) return error.InvalidExistingEventLog;
        try output.writer.writeAll(bytes);
        if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') {
            try output.writer.writeByte('\n');
        }
    }
    try output.writer.writeAll(canonical_input);
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

fn readBindingSnapshot(
    allocator: std.mem.Allocator,
    path: []const u8,
    definition_id: []const u8,
    slot_name: []const u8,
    logical_path: []const u8,
    current_revision: ?[]const u8,
    operation: []const u8,
    idempotency_key: ?[]const u8,
    expected_input_digest: []const u8,
) !BindingSnapshot {
    const bytes = durable_store.readRegularFileNoSymlink(
        allocator,
        path,
        BindingMaxBytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{
            .exists = false,
            .bytes = try allocator.alloc(u8, 0),
            .digest = null,
            .last_revision = null,
            .idempotency_match = false,
        },
        else => return err,
    };
    errdefer allocator.free(bytes);
    const digest = try definition_core.canonical_json.digestBytesAlloc(allocator, bytes);
    errdefer allocator.free(digest);
    var last_revision: ?[]u8 = null;
    errdefer if (last_revision) |revision| allocator.free(revision);
    var idempotency_match = false;
    var row_count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trim(u8, line_with_cr, " \t\r");
        if (line.len == 0) continue;
        row_count += 1;
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .duplicate_field_behavior = .@"error" },
        );
        defer parsed.deinit();
        const object = try definition_core.json.object(parsed.value);
        try definition_core.json.requireExactKeys(object, &.{
            "schema",
            "slot",
            "logical_path",
            "definition_id",
            "definition_digest",
            "abi",
            "operation",
            "input_digest",
            "revision_before",
            "revision_after",
            "idempotency_key",
        });
        try definition_core.json.requireFields(object, &.{
            "schema",
            "slot",
            "logical_path",
            "definition_id",
            "definition_digest",
            "abi",
            "operation",
            "input_digest",
            "revision_before",
            "revision_after",
            "idempotency_key",
        });
        if (!std.mem.eql(
            u8,
            try definition_core.json.requiredString(object, "schema"),
            "ledger-store-binding/v1",
        )) return error.InvalidStoreBinding;
        if (!std.mem.eql(
            u8,
            try definition_core.json.requiredString(object, "slot"),
            slot_name,
        )) return error.StoreBindingSlotMismatch;
        if (!std.mem.eql(
            u8,
            try definition_core.json.requiredString(object, "logical_path"),
            logical_path,
        )) return error.StoreBindingPathMismatch;
        const row_definition_id = try definition_core.json.requiredString(
            object,
            "definition_id",
        );
        try definition_core.json.safeIdentifier(row_definition_id, 256);
        if (!std.mem.eql(u8, row_definition_id, definition_id)) {
            return error.StoreBindingDefinitionMismatch;
        }
        try definition_core.json.digest(
            try definition_core.json.requiredString(object, "definition_digest"),
        );
        if (!std.mem.eql(
            u8,
            try definition_core.json.requiredString(object, "abi"),
            definition.abi,
        )) return error.StoreBindingAbiMismatch;
        const row_input_digest = try definition_core.json.requiredString(
            object,
            "input_digest",
        );
        try definition_core.json.digest(row_input_digest);
        const revision_before = try definition_core.json.optionalString(
            object,
            "revision_before",
        );
        if (revision_before) |revision| try definition_core.json.digest(revision);
        const revision_after = try definition_core.json.requiredString(
            object,
            "revision_after",
        );
        try definition_core.json.digest(revision_after);
        if (last_revision) |prior| {
            if (revision_before == null or
                !std.mem.eql(u8, revision_before.?, prior))
            {
                return error.StoreBindingChainMismatch;
            }
            allocator.free(prior);
        }
        last_revision = try allocator.dupe(u8, revision_after);
        const row_idempotency = try definition_core.json.optionalString(
            object,
            "idempotency_key",
        );
        if (idempotency_key != null and row_idempotency != null and
            std.mem.eql(u8, idempotency_key.?, row_idempotency.?) and
            std.mem.eql(
                u8,
                operation,
                try definition_core.json.requiredString(object, "operation"),
            ))
        {
            if (!std.mem.eql(u8, expected_input_digest, row_input_digest)) {
                return error.IdempotencyConflict;
            }
            idempotency_match = true;
        }
    }
    if (row_count == 0 or last_revision == null) return error.InvalidStoreBinding;
    if (current_revision == null or
        !std.mem.eql(u8, current_revision.?, last_revision.?))
    {
        return error.StoreBindingRevisionMismatch;
    }
    return .{
        .exists = true,
        .bytes = bytes,
        .digest = digest,
        .last_revision = last_revision,
        .idempotency_match = idempotency_match,
    };
}

fn appendBindingRowAlloc(
    allocator: std.mem.Allocator,
    before: []const u8,
    definition_plan: *const definition.Plan,
    slot: storage.Slot,
    operation: []const u8,
    input_digest: []const u8,
    revision_before: ?[]const u8,
    revision_after: []const u8,
    idempotency_key: ?[]const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(before);
    if (before.len != 0 and before[before.len - 1] != '\n') {
        try output.writer.writeByte('\n');
    }
    try output.writer.writeAll(
        "{\"abi\":\"ledger-artifact-abi/v1\",\"definition_digest\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        definition_plan.closure_digest[0..],
    );
    try output.writer.writeAll(",\"definition_id\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        definition_plan.id,
    );
    try output.writer.writeAll(",\"idempotency_key\":");
    try writeOptionalString(&output.writer, idempotency_key);
    try output.writer.writeAll(",\"input_digest\":");
    try definition_core.canonical_json.writeCanonicalString(&output.writer, input_digest);
    try output.writer.writeAll(",\"logical_path\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        slot.relative_path,
    );
    try output.writer.writeAll(",\"operation\":");
    try definition_core.canonical_json.writeCanonicalString(&output.writer, operation);
    try output.writer.writeAll(",\"revision_after\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        revision_after,
    );
    try output.writer.writeAll(",\"revision_before\":");
    try writeOptionalString(&output.writer, revision_before);
    try output.writer.writeAll(",\"schema\":\"ledger-store-binding/v1\",\"slot\":");
    try definition_core.canonical_json.writeCanonicalString(&output.writer, slot.name);
    try output.writer.writeAll("}\n");
    if (output.written().len > BindingMaxBytes) return error.StoreBindingTooLarge;
    return output.toOwnedSlice();
}

fn buildMutations(
    allocator: std.mem.Allocator,
    storage_plan: *const storage.Plan,
    prepared: []const PreparedEffect,
) ![]durable_store.TransactionMutation {
    const mutations = try allocator.alloc(
        durable_store.TransactionMutation,
        prepared.len * 2,
    );
    for (prepared, 0..) |effect, index| {
        const slot = storage_plan.slots[effect.slot_index];
        mutations[index * 2] = .{
            .path = effect.slot_path,
            .text = effect.slot_after,
            .expectation = .{
                .expected_digest = effect.slot_before_digest,
                .expected_exists = effect.slot_before != null,
            },
            .content_mode = .raw,
            .max_bytes = slot.max_bytes,
        };
        mutations[index * 2 + 1] = .{
            .path = effect.binding_path,
            .text = effect.binding_after,
            .expectation = .{
                .expected_digest = effect.binding_before.digest,
                .expected_exists = effect.binding_before.exists,
            },
            .content_mode = .raw,
            .max_bytes = BindingMaxBytes,
        };
    }
    return mutations;
}

fn buildReceipts(
    allocator: std.mem.Allocator,
    storage_plan: *const storage.Plan,
    prepared: []const PreparedEffect,
    idempotent: bool,
) ![]EffectReceipt {
    const receipts = try allocator.alloc(EffectReceipt, prepared.len);
    var initialized: usize = 0;
    errdefer {
        for (receipts[0..initialized]) |*receipt| receipt.deinit(allocator);
        allocator.free(receipts);
    }
    for (prepared, 0..) |effect, index| {
        const slot = storage_plan.slots[effect.slot_index];
        receipts[index] = .{
            .slot = try allocator.dupe(u8, slot.name),
            .logical_ref = try allocator.dupe(u8, slot.relative_path),
            .revision_before = if (effect.slot_before_digest) |revision|
                try allocator.dupe(u8, revision)
            else
                null,
            .revision_after = try allocator.dupe(
                u8,
                if (idempotent)
                    effect.slot_before_digest.?
                else
                    effect.slot_after_digest,
            ),
            .result = try allocator.dupe(
                u8,
                if (idempotent) "idempotent" else switch (effect.kind) {
                    .create_new => "created",
                    .compare_append => "appended",
                    .compare_replace => "replaced",
                },
            ),
        };
        initialized += 1;
    }
    return receipts;
}

fn bindingPathAlloc(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    logical_path: []const u8,
) ![]u8 {
    const digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        logical_path,
    );
    defer allocator.free(digest);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{digest[7..]});
    defer allocator.free(file_name);
    return std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", ".bindings", file_name },
    );
}

fn parameterText(
    bindings: *const definition_core.parameters.Bindings,
    name: []const u8,
) ?[]const u8 {
    for (bindings.items) |binding| {
        if (!std.mem.eql(u8, binding.name, name)) continue;
        return switch (binding.value) {
            .string,
            .digest,
            .timestamp,
            .safe_identifier,
            .relative_path,
            => |text| text,
            .integer, .boolean => null,
        };
    }
    return null;
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try definition_core.canonical_json.writeCanonicalString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

test "transaction appends an event and binding in one durable transaction" {
    var definition_tmp = std.testing.tmpDir(.{});
    defer definition_tmp.cleanup();
    try definition_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/events","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["atomic-transaction","compare-and-append","exact-object"]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","input":"event","path":"","keys":["kind","value"]}]},"constraints":[],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/events.jsonl","codec":"jsonl","max_bytes":65536}}},"operations":{"append":{"op":"atomic-transaction","effects":[{"op":"compare-and-append","slot":"events","input":"event"}]}},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":100,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":16}}
        ,
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

    var first = try transact(
        std.testing.allocator,
        &definition_plan,
        &validation_plan,
        &storage_plan,
        "append",
        repo_root,
        &.{.{ .name = "event", .bytes = "{\"kind\":\"one\",\"value\":1}" }},
        &parameters,
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.storage_mutated);
    try std.testing.expect(!first.semantic_authority_granted);
    try std.testing.expectEqualStrings("appended", first.effects[0].result);

    var second = try transact(
        std.testing.allocator,
        &definition_plan,
        &validation_plan,
        &storage_plan,
        "append",
        repo_root,
        &.{.{ .name = "event", .bytes = "{\"kind\":\"two\",\"value\":2}" }},
        &parameters,
    );
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second.storage_mutated);
    try std.testing.expect(first.transaction_id != null);
    try std.testing.expect(second.transaction_id != null);
    try std.testing.expect(!std.mem.eql(
        u8,
        first.transaction_id.?,
        second.transaction_id.?,
    ));
    try std.testing.expectEqualStrings(
        first.effects[0].revision_after,
        second.effects[0].revision_before.?,
    );
    const event_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ repo_root, ".ledger", "example", "events.jsonl" },
    );
    defer std.testing.allocator.free(event_path);
    const events = try durable_store.readRegularFileNoSymlink(
        std.testing.allocator,
        event_path,
        65536,
    );
    defer std.testing.allocator.free(events);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"one\",\"value\":1}\n{\"kind\":\"two\",\"value\":2}\n",
        events,
    );
    const binding_path = try bindingPathAlloc(
        std.testing.allocator,
        repo_root,
        "example/events.jsonl",
    );
    defer std.testing.allocator.free(binding_path);
    try std.testing.expectError(
        error.StoreBindingDefinitionMismatch,
        readBindingSnapshot(
            std.testing.allocator,
            binding_path,
            "example/other-events",
            "events",
            "example/events.jsonl",
            second.effects[0].revision_after,
            "append",
            null,
            second.effects[0].revision_after,
        ),
    );

    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ repo_root, ".ledger", ".transactions" },
    );
    defer std.testing.allocator.free(transactions_dir);
    const pending_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ transactions_dir, "interrupted.prepared.json" },
    );
    defer std.testing.allocator.free(pending_path);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        pending_path,
        "{}\n",
    );
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        transact(
            std.testing.allocator,
            &definition_plan,
            &validation_plan,
            &storage_plan,
            "append",
            repo_root,
            &.{.{ .name = "event", .bytes = "{\"kind\":\"three\",\"value\":3}" }},
            &parameters,
        ),
    );
}

test "transaction fails closed for an unbound existing store" {
    var definition_tmp = std.testing.tmpDir(.{});
    defer definition_tmp.cleanup();
    try definition_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/unbound","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["compare-and-append"]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{},"constraints":[],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/events.jsonl","codec":"jsonl","max_bytes":4096}}},"operations":{"append":{"effects":[{"op":"compare-and-append","slot":"events","input":"event"}]}},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":4096,"max_records":10,"max_output_bytes":1024,"max_diagnostics":8,"max_reducer_states":4}}
        ,
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
    const event_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ repo_root, ".ledger", "example", "events.jsonl" },
    );
    defer std.testing.allocator.free(event_path);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        event_path,
        "{\"legacy\":true}\n",
    );
    try std.testing.expectError(
        error.UnboundStore,
        transact(
            std.testing.allocator,
            &definition_plan,
            &validation_plan,
            &storage_plan,
            "append",
            repo_root,
            &.{.{ .name = "event", .bytes = "{\"kind\":\"new\"}" }},
            &parameters,
        ),
    );
}
