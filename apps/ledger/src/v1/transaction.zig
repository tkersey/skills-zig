const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const definition_archive = @import("definition_archive.zig");
const materialization = @import("materialization.zig");
const protocol = @import("protocol.zig");
const replay = @import("replay.zig");
const revision_archive = @import("revision_archive.zig");
const storage = @import("storage.zig");
const validation = @import("validation.zig");

threadlocal var runtime_io: ?std.Io = null;
threadlocal var last_mutation_state: ?bool = false;

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
    generated_outputs: []protocol.GeneratedOutput,
    semantic_authority_granted: bool = false,
    storage_mutated: bool,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.validation_result.deinit(allocator);
        allocator.free(self.operation);
        if (self.transaction_id) |transaction_id| allocator.free(transaction_id);
        for (self.effects) |*effect| effect.deinit(allocator);
        allocator.free(self.effects);
        if (self.returned_content) |content| allocator.free(content);
        for (self.generated_outputs) |*output| output.deinit(allocator);
        allocator.free(self.generated_outputs);
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
    binding_before: custody.BindingSnapshot,
    binding_after: []u8,
    canonical_input: []u8,
    generated_outputs: []protocol.GeneratedOutput,
    revision_archive: ?revision_archive.Candidate,
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
        for (self.generated_outputs) |*output| output.deinit(allocator);
        allocator.free(self.generated_outputs);
        if (self.revision_archive) |*archive| archive.deinit(allocator);
        self.* = undefined;
    }
};

pub fn installRuntimeIo(io: std.Io) void {
    runtime_io = io;
    durable_store.installRuntimeIo(io);
}

pub fn lastMutationState() ?bool {
    return last_mutation_state;
}

pub fn transact(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    definition_closure: *const definition_core.Closure,
    definition_entry_path: []const u8,
    validation_plan: *const validation.Plan,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
    operation_name: []const u8,
    repo_root: []const u8,
    documents: []const validation.InputDocument,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    last_mutation_state = false;
    if (!std.fs.path.isAbsolute(repo_root)) return error.RepositoryRootNotAbsolute;
    if (!std.mem.eql(
        u8,
        definition_plan.closure_digest[0..],
        definition_closure.digestSlice(),
    )) return error.DefinitionClosureDigestMismatch;
    var resolved_storage = try storage.resolve(
        allocator,
        storage_plan,
        parameters,
    );
    defer resolved_storage.deinit(allocator);
    const operation = resolved_storage.findOperation(operation_name) orelse
        return error.UnknownOperation;
    if (isBindingOperation(operation)) {
        if (documents.len != 0) {
            return error.BindingOperationRejectsExternalInput;
        }
        return bindExisting(
            allocator,
            definition_plan,
            definition_closure,
            definition_entry_path,
            validation_plan,
            &resolved_storage,
            event_protocol,
            operation,
            operation_name,
            repo_root,
            parameters,
        );
    }
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
            .generated_outputs = try allocator.alloc(protocol.GeneratedOutput, 0),
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
    const definitions_dir = try std.fs.path.join(
        allocator,
        &.{ ledger_root, ".definitions" },
    );
    defer allocator.free(definitions_dir);
    const revisions_dir = try std.fs.path.join(
        allocator,
        &.{ ledger_root, ".revisions" },
    );
    defer allocator.free(revisions_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(ledger_root);
    try durable_store.ensureDirectoryPathNoSymlinks(transactions_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(bindings_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(definitions_dir);
    if (operationNeedsRevisionArchive(operation)) {
        try durable_store.ensureDirectoryPathNoSymlinks(revisions_dir);
    }
    try durable_store.ensureNoPendingTransactions(allocator, transactions_dir);
    var archive = try definition_archive.prepare(
        allocator,
        repo_root,
        definition_plan.id,
        definition_entry_path,
        definition_closure,
    );
    defer archive.deinit(allocator);

    const prepared = try prepareEffects(
        allocator,
        definition_plan,
        &resolved_storage,
        event_protocol,
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
    if (duplicate_count != 0 and !archive.exists) {
        return error.DefinitionArchiveMissing;
    }
    var transaction_id: ?[]u8 = null;
    var storage_mutated = false;
    if (duplicate_count == 0) {
        const mutations = try buildMutations(
            allocator,
            &resolved_storage,
            prepared,
            &archive,
        );
        defer allocator.free(mutations);
        const counter_path = try std.fs.path.join(
            allocator,
            &.{ ledger_root, ".fencing.counter" },
        );
        defer allocator.free(counter_path);
        last_mutation_state = null;
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
        last_mutation_state = true;
        defer commit.deinit(allocator);
        transaction_id = try allocator.dupe(u8, commit.transaction_id);
        storage_mutated = true;
    }
    errdefer if (transaction_id) |value| allocator.free(value);

    const receipts = try buildReceipts(
        allocator,
        &resolved_storage,
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
    const generated_outputs = try collectGeneratedOutputsAlloc(
        allocator,
        prepared,
    );
    errdefer deinitGeneratedOutputs(allocator, generated_outputs);
    const owned_operation = try allocator.dupe(u8, operation_name);
    errdefer allocator.free(owned_operation);
    const validation_result = try execution.takeResult(allocator, definition_plan);
    return .{
        .validation_result = validation_result,
        .operation = owned_operation,
        .transaction_id = transaction_id,
        .effects = receipts,
        .returned_content = returned_content,
        .generated_outputs = generated_outputs,
        .storage_mutated = storage_mutated,
    };
}

const PreparedBinding = struct {
    slot_index: u16,
    input_index: u8,
    slot_path: []u8,
    slot_content: []u8,
    slot_digest: []u8,
    binding_path: []u8,
    binding_after: []u8,

    fn deinit(self: *PreparedBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.slot_path);
        allocator.free(self.slot_content);
        allocator.free(self.slot_digest);
        allocator.free(self.binding_path);
        allocator.free(self.binding_after);
        self.* = undefined;
    }
};

fn isBindingOperation(operation: *const storage.Operation) bool {
    if (operation.effects.len == 0) return false;
    for (operation.effects) |effect| {
        if (effect.kind != .bind_existing) return false;
    }
    return true;
}

fn operationNeedsRevisionArchive(operation: *const storage.Operation) bool {
    for (operation.effects) |effect| {
        if (effect.kind == .compare_replace) return true;
    }
    return false;
}

fn bindExisting(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    definition_closure: *const definition_core.Closure,
    definition_entry_path: []const u8,
    validation_plan: *const validation.Plan,
    storage_plan: *const storage.ResolvedPlan,
    event_protocol: ?*const protocol.Plan,
    operation: *const storage.Operation,
    operation_name: []const u8,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
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
    const definitions_dir = try std.fs.path.join(
        allocator,
        &.{ ledger_root, ".definitions" },
    );
    defer allocator.free(definitions_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(ledger_root);
    try durable_store.ensureDirectoryPathNoSymlinks(transactions_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(bindings_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(definitions_dir);
    try durable_store.ensureNoPendingTransactions(allocator, transactions_dir);
    var archive = try definition_archive.prepare(
        allocator,
        repo_root,
        definition_plan.id,
        definition_entry_path,
        definition_closure,
    );
    defer archive.deinit(allocator);
    const prepared = try allocator.alloc(PreparedBinding, operation.effects.len);
    var prepared_count: usize = 0;
    defer {
        for (prepared[0..prepared_count]) |*item| item.deinit(allocator);
        allocator.free(prepared);
    }
    for (operation.effects, 0..) |effect, index| {
        prepared[index] = try prepareExistingBinding(
            allocator,
            definition_plan,
            validation_plan,
            storage_plan,
            event_protocol,
            effect,
            operation_name,
            repo_root,
            parameters,
        );
        prepared_count += 1;
    }
    const archive_count: usize = if (archive.exists) 0 else 1;
    const mutations = try allocator.alloc(
        durable_store.TransactionMutation,
        prepared.len * 2 + archive_count,
    );
    defer allocator.free(mutations);
    for (prepared, 0..) |item, index| {
        const slot = storage_plan.slot(item.slot_index);
        mutations[index * 2] = .{
            .path = item.slot_path,
            .text = "",
            .expectation = .{
                .expected_digest = item.slot_digest,
                .expected_exists = true,
            },
            .content_mode = .raw,
            .max_bytes = slot.max_bytes,
            .action = .check_only,
        };
        mutations[index * 2 + 1] = .{
            .path = item.binding_path,
            .text = item.binding_after,
            .expectation = .{ .expected_exists = false },
            .content_mode = .raw,
            .max_bytes = custody.binding_max_bytes,
        };
    }
    var mutation_index = prepared.len * 2;
    if (!archive.exists) {
        mutations[mutation_index] = .{
            .path = archive.path,
            .text = archive.content,
            .expectation = .{ .expected_exists = false },
            .content_mode = .raw,
            .max_bytes = definition_archive.max_bytes,
        };
        mutation_index += 1;
    }
    std.debug.assert(mutation_index == mutations.len);
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ ledger_root, ".fencing.counter" },
    );
    defer allocator.free(counter_path);
    last_mutation_state = null;
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
    last_mutation_state = true;
    defer commit.deinit(allocator);
    const receipts = try allocator.alloc(EffectReceipt, prepared.len);
    var receipt_count: usize = 0;
    errdefer {
        for (receipts[0..receipt_count]) |*receipt| receipt.deinit(allocator);
        allocator.free(receipts);
    }
    for (prepared, 0..) |item, index| {
        const slot = storage_plan.slot(item.slot_index);
        {
            const owned_slot = try allocator.dupe(u8, slot.name);
            errdefer allocator.free(owned_slot);
            const owned_ref = try allocator.dupe(u8, slot.relative_path);
            errdefer allocator.free(owned_ref);
            const revision_before = try allocator.dupe(u8, item.slot_digest);
            errdefer allocator.free(revision_before);
            const revision_after = try allocator.dupe(u8, item.slot_digest);
            errdefer allocator.free(revision_after);
            const result = try allocator.dupe(u8, "bound");
            errdefer allocator.free(result);
            receipts[index] = .{
                .slot = owned_slot,
                .logical_ref = owned_ref,
                .revision_before = revision_before,
                .revision_after = revision_after,
                .result = result,
            };
        }
        receipt_count += 1;
    }
    const transaction_id = try allocator.dupe(u8, commit.transaction_id);
    errdefer allocator.free(transaction_id);
    const owned_operation = try allocator.dupe(u8, operation_name);
    errdefer allocator.free(owned_operation);
    const generated_outputs =
        try allocator.alloc(protocol.GeneratedOutput, 0);
    errdefer allocator.free(generated_outputs);
    const validation_result = try bindingValidationResult(
        allocator,
        definition_plan,
        storage_plan,
        prepared,
    );
    return .{
        .validation_result = validation_result,
        .operation = owned_operation,
        .transaction_id = transaction_id,
        .effects = receipts,
        .returned_content = null,
        .generated_outputs = generated_outputs,
        .storage_mutated = true,
    };
}

fn prepareExistingBinding(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    validation_plan: *const validation.Plan,
    storage_plan: *const storage.ResolvedPlan,
    event_protocol: ?*const protocol.Plan,
    effect: storage.Effect,
    operation_name: []const u8,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !PreparedBinding {
    if (effect.kind != .bind_existing) {
        return error.BindingOperationCannotMixEffects;
    }
    const slot = storage_plan.slot(effect.slot_index);
    const slot_path = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", slot.relative_path },
    );
    errdefer allocator.free(slot_path);
    try durable_store.rejectSymlinkComponents(slot_path);
    const slot_content = try durable_store.readRegularFileNoSymlink(
        allocator,
        slot_path,
        slot.max_bytes,
    );
    errdefer allocator.free(slot_content);
    const slot_digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        slot_content,
    );
    errdefer allocator.free(slot_digest);
    const binding_path = try custody.bindingPathAlloc(
        allocator,
        repo_root,
        slot.relative_path,
    );
    errdefer allocator.free(binding_path);
    var before = try custody.readBindingSnapshot(
        allocator,
        binding_path,
        definition_plan.id,
        slot.name,
        slot.relative_path,
        slot_digest,
        null,
    );
    defer before.deinit(allocator);
    if (before.exists) return error.StoreAlreadyBound;
    const record_count = try validateExistingContent(
        allocator,
        definition_plan,
        validation_plan,
        effect,
        slot,
        event_protocol,
        effect.slot_index,
        slot_content,
        parameters,
    );
    const binding_after = try custody.appendBindingRowAlloc(
        allocator,
        before.bytes,
        definition_plan,
        slot,
        operation_name,
        slot_digest,
        slot_digest,
        .{
            .kind = .existing_store_binding,
            .record_start = if (record_count) |_| 0 else null,
            .record_end = record_count,
            .extent_start = 0,
            .extent_end = slot_content.len,
        },
        null,
        slot_digest,
        null,
    );
    return .{
        .slot_index = effect.slot_index,
        .input_index = effect.input_index,
        .slot_path = slot_path,
        .slot_content = slot_content,
        .slot_digest = slot_digest,
        .binding_path = binding_path,
        .binding_after = binding_after,
    };
}

fn validateExistingContent(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    validation_plan: *const validation.Plan,
    effect: storage.Effect,
    slot: storage.ResolvedSlot,
    event_protocol: ?*const protocol.Plan,
    slot_index: u16,
    content: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !?usize {
    const input_index = effect.input_index;
    const input = definition_plan.inputs[input_index];
    if (slot.kind == .document) {
        try validateExistingDocument(
            allocator,
            validation_plan,
            input.name,
            content,
        );
        return null;
    }
    var count: usize = 0;
    const selected_protocol = if (event_protocol) |plan|
        if (plan.target_slot_index == slot_index) plan else null
    else
        null;
    var protocol_state = if (selected_protocol) |plan|
        protocol.ReplayState.init(plan)
    else
        null;
    defer if (protocol_state) |*state| state.deinit(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trim(u8, line_with_cr, " \t\r");
        if (line.len == 0) continue;
        count += 1;
        if (count > definition_plan.bounds.max_records) {
            return error.ExistingStoreRecordBoundsExceeded;
        }
        if (effect.event != null or selected_protocol != null) {
            try validateExistingEvent(
                allocator,
                validation_plan,
                input.name,
                input_index,
                effect.event,
                selected_protocol,
                if (protocol_state) |*state| state else null,
                line,
                parameters,
            );
        } else {
            try validateExistingDocument(
                allocator,
                validation_plan,
                input.name,
                line,
            );
        }
    }
    if (count == 0) return error.ExistingStoreEmpty;
    return count;
}

fn validateExistingDocument(
    allocator: std.mem.Allocator,
    validation_plan: *const validation.Plan,
    input_name: []const u8,
    bytes: []const u8,
) !void {
    var execution = try validation.execute(
        allocator,
        validation_plan,
        &.{.{ .name = input_name, .bytes = bytes }},
    );
    defer execution.deinit();
    if (!execution.isValid()) return error.ExistingStoreValidationFailed;
}

fn validateExistingEvent(
    allocator: std.mem.Allocator,
    validation_plan: *const validation.Plan,
    input_name: []const u8,
    input_index: u8,
    event_materialization: ?storage.EventMaterialization,
    event_protocol: ?*const protocol.Plan,
    protocol_state: ?*protocol.ReplayState,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    if (event_materialization) |materialized| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            bytes,
            .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
            },
        );
        defer parsed.deinit();
        const canonical = switch (materialized.mode) {
            .chained => try definition_core.canonical_json.canonicalJsonAlloc(
                allocator,
                parsed.value,
            ),
            .plain => try protocol.canonicalPlainStoredEventAlloc(
                allocator,
                &materialized,
                parsed.value,
            ),
        };
        defer allocator.free(canonical);
        if (!std.mem.eql(u8, canonical, bytes)) {
            return error.ExistingStoreValidationFailed;
        }
        const reconstructed = switch (materialized.mode) {
            .chained => chained: {
                const plan = event_protocol orelse
                    return error.EventMaterializationRequiresProtocol;
                if (plan.mode != .chained) {
                    return error.EventMaterializationModeMismatch;
                }
                break :chained try protocol.reconstructInputAlloc(
                    allocator,
                    plan,
                    protocol_state orelse
                        return error.EventMaterializationRequiresProtocol,
                    &materialized,
                    parsed.value,
                );
            },
            .plain => plain: {
                if (event_protocol) |plan| {
                    if (plan.mode != .plain or protocol_state == null) {
                        return error.EventMaterializationModeMismatch;
                    }
                } else if (protocol_state != null) {
                    return error.EventMaterializationModeMismatch;
                }
                break :plain try protocol.reconstructPlainInputAlloc(
                    allocator,
                    &materialized,
                    parsed.value,
                );
            },
        };
        defer allocator.free(reconstructed);
        var execution = try validation.execute(
            allocator,
            validation_plan,
            &.{.{ .name = input_name, .bytes = reconstructed }},
        );
        defer execution.deinit();
        if (!execution.isValid()) return error.ExistingStoreValidationFailed;
        if (event_protocol) |plan| {
            try protocol.applyValueBound(
                allocator,
                plan,
                protocol_state orelse
                    return error.EventMaterializationRequiresProtocol,
                parsed.value,
                parameters,
            );
        }
        return;
    }
    var execution = try validation.execute(
        allocator,
        validation_plan,
        &.{.{ .name = input_name, .bytes = bytes }},
    );
    defer execution.deinit();
    if (!execution.isValid()) return error.ExistingStoreValidationFailed;
    if (event_protocol) |plan| {
        const event = execution.inputJson(input_index) orelse
            return error.ExistingProtocolInputMustBeJson;
        try protocol.applyValueBound(
            allocator,
            plan,
            protocol_state orelse
                return error.EventMaterializationRequiresProtocol,
            event,
            parameters,
        );
    }
}

fn bindingValidationResult(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.ResolvedPlan,
    prepared: []const PreparedBinding,
) !validation.Result {
    const input_digests = try allocator.alloc(
        validation.InputDigest,
        prepared.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (input_digests[0..initialized]) |digest| {
            allocator.free(digest.name);
            allocator.free(digest.digest);
        }
        allocator.free(input_digests);
    }
    for (prepared, 0..) |item, index| {
        const slot = storage_plan.slot(item.slot_index);
        {
            const name = try allocator.dupe(u8, slot.name);
            errdefer allocator.free(name);
            const digest = try allocator.dupe(u8, item.slot_digest);
            errdefer allocator.free(digest);
            input_digests[index] = .{
                .name = name,
                .digest = digest,
            };
        }
        initialized += 1;
    }
    std.mem.sort(
        validation.InputDigest,
        input_digests,
        {},
        struct {
            fn lessThan(
                _: void,
                left: validation.InputDigest,
                right: validation.InputDigest,
            ) bool {
                return std.mem.lessThan(u8, left.name, right.name);
            }
        }.lessThan,
    );
    const definition_id = try allocator.dupe(u8, definition_plan.id);
    errdefer allocator.free(definition_id);
    return .{
        .definition_id = definition_id,
        .definition_digest = definition_plan.closure_digest,
        .input_digests = input_digests,
        .diagnostics = definition_core.diagnostics.Collector.init(
            allocator,
            .{
                .max_count = definition_plan.bounds.max_diagnostics,
                .max_total_bytes = 64 * 1024,
                .max_message_bytes = 2048,
            },
        ),
        .valid = true,
    };
}

fn prepareEffects(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.ResolvedPlan,
    event_protocol: ?*const protocol.Plan,
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
            event_protocol,
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
    storage_plan: *const storage.ResolvedPlan,
    event_protocol: ?*const protocol.Plan,
    effect: storage.Effect,
    operation_name: []const u8,
    repo_root: []const u8,
    execution: *const validation.Execution,
    parameters: *const definition_core.parameters.Bindings,
) !PreparedEffect {
    const slot = storage_plan.slot(effect.slot_index);
    const slot_path = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", slot.relative_path },
    );
    errdefer allocator.free(slot_path);
    const binding_path = try custody.bindingPathAlloc(
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
        .bind_existing => return error.BindingOperationRequiresMigrationPath,
    }
    if (effect.expected_revision_parameter) |parameter_name| {
        const expected_revision =
            parameterText(parameters, parameter_name) orelse
            return error.MissingOperationParameter;
        const actual = slot_before_digest orelse return error.RevisionMismatch;
        if (!std.mem.eql(u8, actual, expected_revision)) {
            return error.RevisionMismatch;
        }
    }

    const canonical_request = try materialization.canonicalizeInputAlloc(
        allocator,
        execution,
        effect.input_index,
        definition_plan.inputs[effect.input_index].codec,
    );
    defer allocator.free(canonical_request);
    const parameter_idempotency_key =
        if (effect.idempotency_parameter) |parameter_name|
            parameterText(parameters, parameter_name) orelse
                return error.MissingOperationParameter
        else
            null;
    const derived_idempotency_key = if (effect.event) |*event| blk: {
        const idempotency = event.idempotency orelse break :blk null;
        const bypass = if (idempotency.bypass_parameter) |parameter_name|
            parameterBoolean(parameters, parameter_name) orelse
                return error.MissingOperationParameter
        else
            false;
        if (bypass) break :blk null;
        break :blk try protocol.derivePlainIdempotencyKeyAlloc(
            allocator,
            event,
            execution.inputJson(effect.input_index) orelse
                return error.ProtocolInputMustBeJson,
        );
    } else null;
    defer if (derived_idempotency_key) |key| allocator.free(key);
    const idempotency_key = parameter_idempotency_key orelse
        derived_idempotency_key;
    const input_digest = execution.inputDigest(
        definition_plan.inputs[effect.input_index].name,
    ) orelse return error.InputDigestMissing;
    var binding_before = try custody.readBindingSnapshot(
        allocator,
        binding_path,
        definition_plan.id,
        slot.name,
        slot.relative_path,
        slot_before_digest,
        if (parameter_idempotency_key) |key| .{
            .definition_digest = definition_plan.closure_digest[0..],
            .operation = operation_name,
            .key = key,
            .input_digest = input_digest,
        } else null,
    );
    errdefer binding_before.deinit(allocator);
    if (slot_before != null and !binding_before.exists) return error.UnboundStore;
    if (slot_before == null and binding_before.exists) return error.OrphanedStoreBinding;

    const protocol_required = event_protocol != null and
        event_protocol.?.target_slot_index == effect.slot_index;
    var existing_records: ?usize = null;
    var protocol_state: ?protocol.ReplayState = null;
    if (slot_before) |content| {
        const snapshot: custody.SlotSnapshot = .{
            .path = slot_path,
            .content = content,
            .revision = slot_before_digest.?,
            .binding = binding_before,
        };
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
        if (slot.kind == .event_log) {
            existing_records = replay_stats.records_validated;
        }
        protocol_state = replay_stats.takeProtocolState();
    } else if (slot.kind == .event_log) {
        existing_records = 0;
    }
    defer if (protocol_state) |*state| state.deinit(allocator);
    const derived_idempotency_match =
        if (derived_idempotency_key) |key| match: {
            const content = slot_before orelse break :match null;
            const event = effect.event orelse
                return error.EventIdempotencyRequiresMaterialization;
            const idempotency = event.idempotency orelse
                return error.EventIdempotencyConfigurationMissing;
            break :match try findPlainDerivedIdempotencyMatchAlloc(
                allocator,
                content,
                &event,
                idempotency.derived,
                key,
            );
        } else null;
    defer if (derived_idempotency_match) |content| allocator.free(content);
    const idempotency_match = binding_before.idempotency_match or
        derived_idempotency_match != null;
    var canonical_input_storage: ?[]u8 = null;
    errdefer if (canonical_input_storage) |bytes| allocator.free(bytes);
    var generated_outputs = try allocator.alloc(
        protocol.GeneratedOutput,
        0,
    );
    errdefer deinitGeneratedOutputs(allocator, generated_outputs);
    if (binding_before.idempotency_match and effect.event != null) {
        const content = slot_before orelse return error.InvalidIdempotencyBinding;
        const match_index = binding_before.idempotency_match_index orelse
            return error.InvalidIdempotencyBinding;
        const row = binding_before.rows[match_index];
        if (row.extent_start >= row.extent_end or
            row.extent_end > content.len)
        {
            return error.InvalidIdempotencyBinding;
        }
        canonical_input_storage = try allocator.dupe(
            u8,
            content[row.extent_start..row.extent_end],
        );
    } else if (derived_idempotency_match) |content| {
        canonical_input_storage = try allocator.dupe(u8, content);
    } else if (effect.event) |*event_materialization| {
        var materialized_event = switch (event_materialization.mode) {
            .chained => chained: {
                if (!protocol_required) {
                    return error.EventMaterializationRequiresProtocol;
                }
                const current_protocol = event_protocol.?;
                if (current_protocol.mode != .chained) {
                    return error.EventMaterializationModeMismatch;
                }
                if (protocol_state == null) {
                    protocol_state = protocol.ReplayState.init(
                        current_protocol,
                    );
                }
                break :chained try protocol.materializeEvent(
                    allocator,
                    current_protocol,
                    &protocol_state.?,
                    event_materialization,
                    execution.inputJson(effect.input_index) orelse
                        return error.ProtocolInputMustBeJson,
                    parameters,
                    currentUnixSeconds(),
                    defaultIo(),
                );
            },
            .plain => plain: {
                if (protocol_required) {
                    const current_protocol = event_protocol.?;
                    if (current_protocol.mode != .plain) {
                        return error.EventMaterializationModeMismatch;
                    }
                    if (protocol_state == null) {
                        protocol_state = protocol.ReplayState.init(
                            current_protocol,
                        );
                    }
                }
                break :plain try protocol.materializePlainEvent(
                    allocator,
                    event_materialization,
                    execution.inputJson(effect.input_index) orelse
                        return error.ProtocolInputMustBeJson,
                    parameters,
                    currentUnixSeconds(),
                    defaultIo(),
                );
            },
        };
        allocator.free(generated_outputs);
        canonical_input_storage = materialized_event.content;
        generated_outputs = materialized_event.generated_outputs;
        materialized_event = undefined;
        if (protocol_required) {
            try protocol.applyBound(
                allocator,
                event_protocol.?,
                &protocol_state.?,
                canonical_input_storage.?,
                parameters,
            );
        }
    } else {
        canonical_input_storage = try allocator.dupe(u8, canonical_request);
        if (protocol_required and !idempotency_match) {
            const current_protocol = event_protocol.?;
            if (protocol_state == null) {
                protocol_state = protocol.ReplayState.init(current_protocol);
            }
            try protocol.applyValueBound(
                allocator,
                current_protocol,
                &protocol_state.?,
                execution.inputJson(effect.input_index) orelse
                    return error.ProtocolInputMustBeJson,
                parameters,
            );
        }
    }
    const canonical_input = canonical_input_storage orelse
        return error.CanonicalInputMissing;
    const canonical_input_digest =
        try definition_core.canonical_json.digestBytesAlloc(
            allocator,
            canonical_input,
        );
    defer allocator.free(canonical_input_digest);

    const slot_after: SlotAfter = slot_after: {
        if (idempotency_match) {
            const prior = slot_before orelse return error.InvalidIdempotencyBinding;
            const prior_digest = slot_before_digest orelse
                return error.InvalidIdempotencyBinding;
            const bytes = try allocator.dupe(u8, prior);
            errdefer allocator.free(bytes);
            break :slot_after .{
                .bytes = bytes,
                .digest = try allocator.dupe(u8, prior_digest),
                .extent = null,
            };
        }
        const content = try slotContentAfter(
            allocator,
            slot,
            effect.kind,
            slot_before,
            existing_records,
            canonical_input,
        );
        errdefer allocator.free(content.bytes);
        if (content.bytes.len > slot.max_bytes) {
            return error.StorageSlotBoundsExceeded;
        }
        if (content.extent.record_end) |record_end| {
            if (record_end > definition_plan.bounds.max_records) {
                return error.TransactionRecordBoundsExceeded;
            }
        }
        const digest = try definition_core.canonical_json.digestBytesAlloc(
            allocator,
            content.bytes,
        );
        errdefer allocator.free(digest);
        break :slot_after .{
            .bytes = content.bytes,
            .digest = digest,
            .extent = content.extent,
        };
    };
    errdefer allocator.free(slot_after.bytes);
    errdefer allocator.free(slot_after.digest);

    var revision_candidate: ?revision_archive.Candidate = null;
    errdefer if (revision_candidate) |*candidate| candidate.deinit(allocator);
    if (effect.kind == .compare_replace and binding_before.idempotency_match) {
        const match_index = binding_before.idempotency_match_index orelse
            return error.InvalidIdempotencyBinding;
        const prior_revision =
            binding_before.rows[match_index].revision_before orelse
            return error.InvalidIdempotencyBinding;
        const prior_content = try revision_archive.load(
            allocator,
            repo_root,
            prior_revision,
            slot.max_bytes,
        );
        defer allocator.free(prior_content);
    } else if (effect.kind == .compare_replace) {
        revision_candidate = try revision_archive.prepare(
            allocator,
            repo_root,
            slot_before_digest.?,
            slot_before.?,
            slot.max_bytes,
        );
    }

    const binding_after = if (idempotency_match)
        try allocator.dupe(u8, binding_before.bytes)
    else
        try custody.appendBindingRowAlloc(
            allocator,
            binding_before.bytes,
            definition_plan,
            slot,
            operation_name,
            input_digest,
            canonical_input_digest,
            slot_after.extent.?,
            slot_before_digest,
            slot_after.digest,
            idempotency_key,
        );
    return .{
        .slot_index = effect.slot_index,
        .kind = effect.kind,
        .slot_path = slot_path,
        .binding_path = binding_path,
        .slot_before = slot_before,
        .slot_before_digest = slot_before_digest,
        .slot_after = slot_after.bytes,
        .slot_after_digest = slot_after.digest,
        .binding_before = binding_before,
        .binding_after = binding_after,
        .canonical_input = canonical_input,
        .generated_outputs = generated_outputs,
        .revision_archive = revision_candidate,
        .idempotency_match = idempotency_match,
    };
}

const SlotContent = struct {
    bytes: []u8,
    extent: custody.BindingExtent,
};

const SlotAfter = struct {
    bytes: []u8,
    digest: []u8,
    extent: ?custody.BindingExtent,
};

fn slotContentAfter(
    allocator: std.mem.Allocator,
    slot: storage.ResolvedSlot,
    kind: storage.EffectKind,
    before: ?[]const u8,
    existing_records: ?usize,
    canonical_input: []const u8,
) !SlotContent {
    if (kind != .compare_append) {
        const record_count: ?usize = if (slot.kind == .event_log) blk: {
            const result = durable_store.validateJsonlBytes(
                allocator,
                canonical_input,
            );
            if (!result.ok()) return error.InvalidEventLogInput;
            if (result.lines == 0) return error.InvalidEventLogInput;
            break :blk result.lines;
        } else null;
        return .{
            .bytes = try allocator.dupe(u8, canonical_input),
            .extent = .{
                .kind = .admission,
                .record_start = if (record_count != null) 0 else null,
                .record_end = record_count,
                .extent_start = 0,
                .extent_end = canonical_input.len,
            },
        };
    }
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
    const record_start = existing_records orelse
        return error.ExistingEventRecordCountMissing;
    if (before) |bytes| {
        try output.writer.writeAll(bytes);
        if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') {
            try output.writer.writeByte('\n');
        }
    }
    const extent_start = output.written().len;
    try output.writer.writeAll(canonical_input);
    const extent_end = output.written().len;
    try output.writer.writeByte('\n');
    return .{
        .bytes = try output.toOwnedSlice(),
        .extent = .{
            .kind = .admission,
            .record_start = record_start,
            .record_end = record_start + 1,
            .extent_start = extent_start,
            .extent_end = extent_end,
        },
    };
}

fn buildMutations(
    allocator: std.mem.Allocator,
    storage_plan: *const storage.ResolvedPlan,
    prepared: []const PreparedEffect,
    archive: *const definition_archive.Candidate,
) ![]durable_store.TransactionMutation {
    const archive_count: usize = if (archive.exists) 0 else 1;
    const revision_count = countMissingRevisionArchives(prepared);
    const mutations = try allocator.alloc(
        durable_store.TransactionMutation,
        prepared.len * 2 + revision_count + archive_count,
    );
    for (prepared, 0..) |effect, index| {
        const slot = storage_plan.slot(effect.slot_index);
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
            .max_bytes = custody.binding_max_bytes,
        };
    }
    var mutation_index = prepared.len * 2;
    for (prepared, 0..) |effect, index| {
        const revision = effect.revision_archive orelse continue;
        if (revision.exists or revisionAppearedEarlier(prepared, index)) {
            continue;
        }
        const slot = storage_plan.slot(effect.slot_index);
        mutations[mutation_index] = .{
            .path = revision.path,
            .text = effect.slot_before.?,
            .expectation = .{ .expected_exists = false },
            .content_mode = .raw,
            .max_bytes = slot.max_bytes,
        };
        mutation_index += 1;
    }
    if (!archive.exists) {
        mutations[mutation_index] = .{
            .path = archive.path,
            .text = archive.content,
            .expectation = .{ .expected_exists = false },
            .content_mode = .raw,
            .max_bytes = definition_archive.max_bytes,
        };
        mutation_index += 1;
    }
    std.debug.assert(mutation_index == mutations.len);
    return mutations;
}

fn countMissingRevisionArchives(prepared: []const PreparedEffect) usize {
    var count: usize = 0;
    for (prepared, 0..) |effect, index| {
        const revision = effect.revision_archive orelse continue;
        if (!revision.exists and !revisionAppearedEarlier(prepared, index)) {
            count += 1;
        }
    }
    return count;
}

fn revisionAppearedEarlier(
    prepared: []const PreparedEffect,
    index: usize,
) bool {
    for (prepared[0..index]) |prior| {
        const prior_revision = prior.revision_archive orelse continue;
        if (std.mem.eql(
            u8,
            prior_revision.path,
            prepared[index].revision_archive.?.path,
        )) {
            return true;
        }
    }
    return false;
}

fn buildReceipts(
    allocator: std.mem.Allocator,
    storage_plan: *const storage.ResolvedPlan,
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
        const slot = storage_plan.slot(effect.slot_index);
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
                    .bind_existing => "bound",
                },
            ),
        };
        initialized += 1;
    }
    return receipts;
}

fn collectGeneratedOutputsAlloc(
    allocator: std.mem.Allocator,
    prepared: []const PreparedEffect,
) ![]protocol.GeneratedOutput {
    var count: usize = 0;
    for (prepared) |effect| {
        count = std.math.add(
            usize,
            count,
            effect.generated_outputs.len,
        ) catch return error.GeneratedOutputCountOverflow;
    }
    if (count > 1024) return error.GeneratedOutputCountExceeded;
    const outputs = try allocator.alloc(protocol.GeneratedOutput, count);
    var initialized: usize = 0;
    errdefer {
        for (outputs[0..initialized]) |*output| output.deinit(allocator);
        allocator.free(outputs);
    }
    for (prepared) |effect| {
        for (effect.generated_outputs) |output| {
            const name = try allocator.dupe(u8, output.name);
            errdefer allocator.free(name);
            const value = try allocator.dupe(u8, output.value);
            errdefer allocator.free(value);
            outputs[initialized] = .{
                .name = name,
                .value = value,
            };
            initialized += 1;
        }
    }
    std.mem.sort(
        protocol.GeneratedOutput,
        outputs,
        {},
        struct {
            fn lessThan(
                _: void,
                left: protocol.GeneratedOutput,
                right: protocol.GeneratedOutput,
            ) bool {
                return std.mem.lessThan(u8, left.name, right.name);
            }
        }.lessThan,
    );
    if (outputs.len > 1) {
        for (outputs[1..], 1..) |output, index| {
            if (std.mem.eql(u8, outputs[index - 1].name, output.name)) {
                return error.DuplicateGeneratedOutput;
            }
        }
    }
    return outputs;
}

fn deinitGeneratedOutputs(
    allocator: std.mem.Allocator,
    outputs: []protocol.GeneratedOutput,
) void {
    for (outputs) |*output| output.deinit(allocator);
    allocator.free(outputs);
}

fn findPlainDerivedIdempotencyMatchAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
    event_materialization: *const storage.EventMaterialization,
    name: []const u8,
    expected: []const u8,
) !?[]u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trim(u8, line_with_cr, " \t\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
            },
        );
        defer parsed.deinit();
        const actual = try protocol.storedPlainDerivedValue(
            event_materialization,
            parsed.value,
            name,
        ) orelse return error.EventIdempotencyStoredValueMissing;
        if (!std.mem.eql(u8, actual, expected)) continue;
        const match = try allocator.dupe(u8, line);
        return match;
    }
    return null;
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

fn parameterBoolean(
    bindings: *const definition_core.parameters.Bindings,
    name: []const u8,
) ?bool {
    for (bindings.items) |binding| {
        if (!std.mem.eql(u8, binding.name, name)) continue;
        return switch (binding.value) {
            .boolean => |flag| flag,
            else => null,
        };
    }
    return null;
}

fn currentUnixSeconds() i64 {
    return @intCast(@divFloor(
        std.Io.Clock.real.now(defaultIo()).nanoseconds,
        std.time.ns_per_s,
    ));
}

fn defaultIo() std.Io {
    return runtime_io orelse std.Io.Threaded.global_single_threaded.io();
}

const ChainedEvent = struct {
    bytes: []u8,
    digest: []u8,

    fn deinit(self: *ChainedEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.digest);
        self.* = undefined;
    }
};

fn chainedEventAlloc(
    allocator: std.mem.Allocator,
    sequence: u64,
    kind: []const u8,
    previous: ?[]const u8,
    body: []const u8,
) !ChainedEvent {
    const body_digest =
        try definition_core.canonical_json.digestBytesAlloc(
            allocator,
            body,
        );
    defer allocator.free(body_digest);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"body\":");
    try output.writer.writeAll(body);
    try output.writer.writeAll(",\"body_digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        body_digest,
    );
    try output.writer.writeAll(",\"event_digest\":\"\",\"kind\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        kind,
    );
    try output.writer.writeAll(",\"previous_digest\":");
    if (previous) |digest| {
        try definition_core.canonical_json.writeCanonicalString(
            &output.writer,
            digest,
        );
    } else {
        try output.writer.writeAll("null");
    }
    try output.writer.print(",\"sequence\":{d}}}", .{sequence});
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        output.written(),
        .{ .duplicate_field_behavior = .@"error" },
    );
    defer parsed.deinit();
    const digest =
        try definition_core.canonical_json.fingerprintObjectOmittingAlloc(
            allocator,
            parsed.value,
            "event_digest",
        );
    errdefer allocator.free(digest);
    const bytes = try definition_core.canonical_json.finalizeFingerprintAlloc(
        allocator,
        output.written(),
        "event_digest",
    );
    return .{ .bytes = bytes, .digest = digest };
}

test "transaction appends an event and binding in one durable transaction" {
    var definition_tmp = std.testing.tmpDir(.{});
    defer definition_tmp.cleanup();
    try definition_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/events","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["atomic-transaction","compare-and-append","exact-object","idempotency-key"]},"parameters":{"request":{"type":"safe_identifier","required":true}},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","input":"event","path":"","keys":["kind","value"]}]},"constraints":[],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/events.jsonl","codec":"jsonl","max_bytes":65536}}},"operations":{"append":{"op":"atomic-transaction","effects":[{"op":"compare-and-append","slot":"events","input":"event","idempotency_param":"request"}]}},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":2,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":16}}
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
    var first_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "request", .raw_value = "first" }},
    );
    defer first_parameters.deinit(std.testing.allocator);
    var second_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "request", .raw_value = "second" }},
    );
    defer second_parameters.deinit(std.testing.allocator);
    var third_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "request", .raw_value = "third" }},
    );
    defer third_parameters.deinit(std.testing.allocator);
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
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        null,
        "append",
        repo_root,
        &.{.{ .name = "event", .bytes = "{\"kind\":\"one\",\"value\":1}" }},
        &first_parameters,
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.storage_mutated);
    try std.testing.expect(lastMutationState().?);
    try std.testing.expect(!first.semantic_authority_granted);
    try std.testing.expectEqualStrings("appended", first.effects[0].result);

    var second = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        null,
        "append",
        repo_root,
        &.{.{ .name = "event", .bytes = "{\"kind\":\"two\",\"value\":2}" }},
        &second_parameters,
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
    var duplicate = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        null,
        "append",
        repo_root,
        &.{.{ .name = "event", .bytes = "{\"kind\":\"two\",\"value\":2}" }},
        &second_parameters,
    );
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expect(!duplicate.storage_mutated);
    try std.testing.expect(!lastMutationState().?);
    try std.testing.expectEqualStrings("idempotent", duplicate.effects[0].result);
    try std.testing.expectEqualStrings(
        second.effects[0].revision_after,
        duplicate.effects[0].revision_after,
    );
    try std.testing.expectError(
        error.TransactionRecordBoundsExceeded,
        transact(
            std.testing.allocator,
            &definition_plan,
            &closure,
            "protocol.json",
            &validation_plan,
            &storage_plan,
            null,
            "append",
            repo_root,
            &.{.{ .name = "event", .bytes = "{\"kind\":\"three\",\"value\":3}" }},
            &third_parameters,
        ),
    );
    try std.testing.expect(!lastMutationState().?);
    var resolved_storage = try storage.resolve(
        std.testing.allocator,
        &storage_plan,
        &first_parameters,
    );
    defer resolved_storage.deinit(std.testing.allocator);
    var bounded_snapshot = try custody.readSlot(
        std.testing.allocator,
        repo_root,
        definition_plan.id,
        resolved_storage.slot(0),
    );
    defer bounded_snapshot.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.CurrentStoreRecordBoundsExceeded,
        replay.validateSlot(
            std.testing.allocator,
            repo_root,
            definition_plan.id,
            resolved_storage.slot(0),
            &bounded_snapshot,
            &first_parameters,
            1,
            false,
        ),
    );
    const binding_path = try custody.bindingPathAlloc(
        std.testing.allocator,
        repo_root,
        "example/events.jsonl",
    );
    defer std.testing.allocator.free(binding_path);
    try std.testing.expectError(
        error.StoreBindingDefinitionMismatch,
        custody.readBindingSnapshot(
            std.testing.allocator,
            binding_path,
            "example/other-events",
            "events",
            "example/events.jsonl",
            second.effects[0].revision_after,
            null,
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
            &closure,
            "protocol.json",
            &validation_plan,
            &storage_plan,
            null,
            "append",
            repo_root,
            &.{.{ .name = "event", .bytes = "{\"kind\":\"three\",\"value\":3}" }},
            &third_parameters,
        ),
    );
}

test "transaction materializes passive event requests before chained append" {
    var definition_tmp = std.testing.tmpDir(.{});
    defer definition_tmp.cleanup();
    try definition_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/materialized-events","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["body-digest","canonical-json","compare-and-append","event-digest","event-envelope","event-kinds","event-materialization","exact-object","idempotency-key","previous-digest","replay","secure-token","sequence","sha256"]},"parameters":{"request":{"type":"safe_identifier","required":true}},"inputs":{"request":{"codec":"json","max_bytes":4096}},"canonicalization":{"steps":[{"op":"canonical-json","input":"request"}]},"shape":{"rules":[{"op":"exact-object","input":"request","path":"","keys":["body","construction_ref","goal_id","kind","subject_digest"]},{"op":"event-envelope","input":"request","keys":["body","body_digest","construction_ref","event_digest","event_id","goal_id","kind","previous_digest","recorded_at","schema","sequence","subject_digest"],"sequence":"/sequence","kind":"/kind","previous_digest":"/previous_digest","body":"/body","body_digest":"/body_digest","event_digest":"/event_digest"}]},"constraints":[{"op":"sequence","start":1},{"op":"previous-digest","genesis":"sha256:0000000000000000000000000000000000000000000000000000000000000000"},{"op":"body-digest"},{"op":"event-digest"},{"op":"event-kinds","values":["created","updated"]}],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/materialized-events.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},"operations":{"append":{"effects":[{"op":"compare-and-append","slot":"events","input":"request","idempotency_param":"request","event":{"mode":"chained","body_input_field":"body","fields":[{"field":"construction_ref","input_field":"construction_ref"},{"field":"event_id","sequence_text_prefix":"e-"},{"field":"goal_id","input_field":"goal_id"},{"field":"kind","input_field":"kind"},{"field":"recorded_at","unix_seconds":true},{"field":"schema","literal":"example-event/v1"},{"field":"subject_digest","input_field":"subject_digest"}],"generate":[{"name":"capability","op":"secure-token","prefix":"AKC2-","bytes":32}],"body_fields":[{"field":"capability_digest","generated_sha256":"capability"}]}}]}},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":3,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}}
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
    var storage_encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer storage_encoder.deinit();
    try storage.encodeCache(&storage_plan, &storage_encoder);
    const storage_payload = try storage_encoder.toOwnedSlice();
    defer std.testing.allocator.free(storage_payload);
    var storage_decoder = definition_core.cache.Decoder.init(storage_payload);
    var cached_storage = try storage.decodeCache(
        std.testing.allocator,
        &storage_decoder,
    );
    defer cached_storage.deinit(std.testing.allocator);
    try storage_decoder.finish();
    try storage.validateCachePlan(&cached_storage, &definition_plan);
    var cached_protocol = (try protocol.compile(
        std.testing.allocator,
        &definition_plan,
        &cached_storage,
    )).?;
    defer cached_protocol.deinit(std.testing.allocator);
    var protocol_plan = (try protocol.compile(
        std.testing.allocator,
        &definition_plan,
        &storage_plan,
    )).?;
    defer protocol_plan.deinit(std.testing.allocator);
    var first_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "request", .raw_value = "first" }},
    );
    defer first_parameters.deinit(std.testing.allocator);
    var second_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "request", .raw_value = "second" }},
    );
    defer second_parameters.deinit(std.testing.allocator);
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    const first_request =
        "{\"body\":{\"id\":\"item-1\"},\"construction_ref\":null,\"goal_id\":\"goal-1\",\"kind\":\"created\",\"subject_digest\":null}";
    var first = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        &protocol_plan,
        "append",
        repo_root,
        &.{.{ .name = "request", .bytes = first_request }},
        &first_parameters,
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.storage_mutated);
    try std.testing.expectEqual(
        @as(usize, 1),
        first.generated_outputs.len,
    );
    try std.testing.expectEqualStrings(
        "capability",
        first.generated_outputs[0].name,
    );
    try std.testing.expectEqual(
        @as(usize, "AKC2-".len + 64),
        first.generated_outputs[0].value.len,
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        first.generated_outputs[0].value,
        "AKC2-",
    ));
    const first_event = first.returned_content orelse
        return error.TestExpectedEqual;
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            first_event,
            first.generated_outputs[0].value,
        ) == null,
    );
    var first_parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        first_event,
        .{},
    );
    defer first_parsed.deinit();
    const first_object = try definition_core.json.object(first_parsed.value);
    const first_body = try definition_core.json.object(
        try definition_core.json.field(first_object, "body"),
    );
    const capability_digest =
        try definition_core.canonical_json.digestBytesAlloc(
            std.testing.allocator,
            first.generated_outputs[0].value,
        );
    defer std.testing.allocator.free(capability_digest);
    try std.testing.expectEqualStrings(
        capability_digest,
        try definition_core.json.requiredString(
            first_body,
            "capability_digest",
        ),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try definition_core.json.integer(
            try definition_core.json.field(first_object, "sequence"),
        ),
    );
    try std.testing.expectEqualStrings(
        "e-1",
        try definition_core.json.requiredString(first_object, "event_id"),
    );
    try std.testing.expectEqualStrings(
        "example-event/v1",
        try definition_core.json.requiredString(first_object, "schema"),
    );
    try std.testing.expectEqualStrings(
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        try definition_core.json.requiredString(
            first_object,
            "previous_digest",
        ),
    );
    const first_digest = try definition_core.json.requiredString(
        first_object,
        "event_digest",
    );
    const second_request =
        "{\"body\":{\"id\":\"item-1\"},\"construction_ref\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"goal_id\":\"goal-1\",\"kind\":\"updated\",\"subject_digest\":\"sha256:2222222222222222222222222222222222222222222222222222222222222222\"}";
    var second = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        &protocol_plan,
        "append",
        repo_root,
        &.{.{ .name = "request", .bytes = second_request }},
        &second_parameters,
    );
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        @as(usize, 1),
        second.generated_outputs.len,
    );
    const second_event = second.returned_content orelse
        return error.TestExpectedEqual;
    var second_parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        second_event,
        .{},
    );
    defer second_parsed.deinit();
    const second_object = try definition_core.json.object(second_parsed.value);
    try std.testing.expectEqual(
        @as(i64, 2),
        try definition_core.json.integer(
            try definition_core.json.field(second_object, "sequence"),
        ),
    );
    try std.testing.expectEqualStrings(
        first_digest,
        try definition_core.json.requiredString(
            second_object,
            "previous_digest",
        ),
    );
    var duplicate = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        &protocol_plan,
        "append",
        repo_root,
        &.{.{ .name = "request", .bytes = second_request }},
        &second_parameters,
    );
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expect(!duplicate.storage_mutated);
    try std.testing.expectEqual(
        @as(usize, 0),
        duplicate.generated_outputs.len,
    );
    try std.testing.expectEqualStrings(
        second_event,
        duplicate.returned_content.?,
    );
    var resolved_storage = try storage.resolve(
        std.testing.allocator,
        &storage_plan,
        &first_parameters,
    );
    defer resolved_storage.deinit(std.testing.allocator);
    var snapshot = try custody.readSlot(
        std.testing.allocator,
        repo_root,
        definition_plan.id,
        resolved_storage.slot(0),
    );
    defer snapshot.deinit(std.testing.allocator);
    var replay_stats = try replay.validateSlot(
        std.testing.allocator,
        repo_root,
        definition_plan.id,
        resolved_storage.slot(0),
        &snapshot,
        &first_parameters,
        3,
        true,
    );
    defer replay_stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), replay_stats.records_validated);
}

test "plain event materialization preserves declared bytes through replay and binding" {
    var definition_tmp = std.testing.tmpDir(.{});
    defer definition_tmp.cleanup();
    try definition_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{
        \\  "schema":"ledger-artifact-definition/v1",
        \\  "id":"example/plain-events",
        \\  "owner":"example",
        \\  "requires":{"abi":"ledger-artifact-abi/v1","operators":["bind-existing","canonical-json","compare-and-append","event-materialization","exact-object"]},
        \\  "parameters":{},
        \\  "inputs":{"request":{"codec":"json","max_bytes":4096}},
        \\  "canonicalization":{"steps":[{"op":"canonical-json","input":"request"}]},
        \\  "shape":{"rules":[
        \\    {"op":"exact-object","input":"request","path":"","keys":["record"]},
        \\    {"op":"exact-object","input":"request","path":"/record","keys":["id","status"]}
        \\  ]},
        \\  "constraints":[],
        \\  "identity":{},
        \\  "storage":{"kind":"event-log","slots":{"events":{"path":"example/plain-events.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},
        \\  "operations":{
        \\    "append":{"effects":[{"op":"compare-and-append","slot":"events","input":"request","event":{
        \\      "mode":"plain",
        \\      "body_input_field":"record",
        \\      "field_order":["v","source","event","record"],
        \\      "body_order":["status","id"],
        \\      "fields":[
        \\        {"field":"event","literal":"capture"},
        \\        {"field":"source","literal":"example"},
        \\        {"field":"v","literal":1}
        \\      ]
        \\    }}]},
        \\    "bind-existing":{"effects":[{"op":"bind-existing","slot":"events","input":"request","event":{
        \\      "mode":"plain",
        \\      "body_input_field":"record",
        \\      "field_order":["v","source","event","record"],
        \\      "body_order":["status","id"],
        \\      "fields":[
        \\        {"field":"event","literal":"capture"},
        \\        {"field":"source","literal":"example"},
        \\        {"field":"v","literal":1}
        \\      ]
        \\    }}]}
        \\  },
        \\  "projections":{},
        \\  "bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}
        \\}
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
    var storage_encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer storage_encoder.deinit();
    try storage.encodeCache(&storage_plan, &storage_encoder);
    const storage_payload = try storage_encoder.toOwnedSlice();
    defer std.testing.allocator.free(storage_payload);
    var storage_decoder = definition_core.cache.Decoder.init(storage_payload);
    var cached_storage = try storage.decodeCache(
        std.testing.allocator,
        &storage_decoder,
    );
    defer cached_storage.deinit(std.testing.allocator);
    try storage_decoder.finish();
    try storage.validateCachePlan(&cached_storage, &definition_plan);
    const cached_event = cached_storage.operations[1].effects[0].event.?;
    try std.testing.expectEqual(storage.EventMaterializationMode.plain, cached_event.mode);
    try std.testing.expectEqualStrings("v", cached_event.field_order[0]);
    try std.testing.expectEqualStrings("status", cached_event.body_order[0]);
    try std.testing.expect((try protocol.compile(
        std.testing.allocator,
        &definition_plan,
        &cached_storage,
    )) == null);
    var parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{},
    );
    defer parameters.deinit(std.testing.allocator);
    const request = "{\"record\":{\"id\":\"item-1\",\"status\":\"open\"}}";
    const expected =
        "{\"v\":1,\"source\":\"example\",\"event\":\"capture\",\"record\":{\"status\":\"open\",\"id\":\"item-1\"}}";

    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    var appended = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &cached_storage,
        null,
        "append",
        repo_root,
        &.{.{ .name = "request", .bytes = request }},
        &parameters,
    );
    defer appended.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, appended.returned_content.?);
    var resolved = try storage.resolve(
        std.testing.allocator,
        &cached_storage,
        &parameters,
    );
    defer resolved.deinit(std.testing.allocator);
    var snapshot = try custody.readSlot(
        std.testing.allocator,
        repo_root,
        definition_plan.id,
        resolved.slot(0),
    );
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected ++ "\n", snapshot.content);
    var replay_stats = try replay.validateSlot(
        std.testing.allocator,
        repo_root,
        definition_plan.id,
        resolved.slot(0),
        &snapshot,
        &parameters,
        4,
        false,
    );
    defer replay_stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), replay_stats.records_validated);

    var binding_tmp = std.testing.tmpDir(.{});
    defer binding_tmp.cleanup();
    const binding_root = try binding_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(binding_root);
    const event_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ binding_root, ".ledger", "example" },
    );
    defer std.testing.allocator.free(event_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(event_dir);
    const event_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ event_dir, "plain-events.jsonl" },
    );
    defer std.testing.allocator.free(event_path);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        event_path,
        expected ++ "\n",
    );
    var bound = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &cached_storage,
        null,
        "bind-existing",
        binding_root,
        &.{},
        &parameters,
    );
    defer bound.deinit(std.testing.allocator);
    try std.testing.expect(bound.storage_mutated);
    try std.testing.expectEqualStrings(
        "bound",
        bound.effects[0].result,
    );
}

test "transaction keeps generated capabilities transient and checks retained custody" {
    var definition_tmp = std.testing.tmpDir(.{});
    defer definition_tmp.cleanup();
    try definition_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{
        \\  "schema":"ledger-artifact-definition/v1",
        \\  "id":"example/capability-protocol",
        \\  "owner":"example",
        \\  "requires":{"abi":"ledger-artifact-abi/v1","operators":["body-digest","canonical-json","compare-and-append","cross-input-equal","enum","event-digest","event-envelope","event-kinds","event-materialization","exact-object","path-format","previous-digest","reducer","replay","secure-token","sequence","sha256"]},
        \\  "parameters":{
        \\    "capability":{"type":"string","required":false},
        \\    "stream":{"type":"safe_identifier","required":true}
        \\  },
        \\  "inputs":{
        \\    "abort":{"codec":"json","required":false,"max_bytes":4096},
        \\    "consume":{"codec":"json","required":false,"max_bytes":4096},
        \\    "prepare":{"codec":"json","required":false,"max_bytes":4096}
        \\  },
        \\  "canonicalization":{"steps":[
        \\    {"op":"canonical-json","input":"abort"},
        \\    {"op":"canonical-json","input":"consume"},
        \\    {"op":"canonical-json","input":"prepare"}
        \\  ]},
        \\  "shape":{"rules":[
        \\    {"op":"exact-object","input":"abort","path":"","keys":["body","kind","stream_id"]},
        \\    {"op":"enum","input":"abort","path":"/kind","values":["aborted"]},
        \\    {"op":"exact-object","input":"abort","path":"/body","keys":["step_id"]},
        \\    {"op":"exact-object","input":"consume","path":"","keys":["body","kind","stream_id"]},
        \\    {"op":"enum","input":"consume","path":"/kind","values":["consumed"]},
        \\    {"op":"exact-object","input":"consume","path":"/body","keys":["step_id"]},
        \\    {"op":"exact-object","input":"prepare","path":"","keys":["body","kind","stream_id"]},
        \\    {"op":"enum","input":"prepare","path":"/kind","values":["prepared"]},
        \\    {"op":"exact-object","input":"prepare","path":"/body","keys":["step_id"]},
        \\    {"op":"event-envelope","input":"prepare","keys":["body","body_digest","event_digest","kind","previous_digest","sequence","stream_id"],"sequence":"/sequence","kind":"/kind","previous_digest":"/previous_digest","body":"/body","body_digest":"/body_digest","event_digest":"/event_digest","partition_bindings":[{"parameter":"stream","event_value":"/stream_id"}]}
        \\  ]},
        \\  "constraints":[
        \\    {"op":"sequence","start":1},
        \\    {"op":"previous-digest","genesis":null},
        \\    {"op":"body-digest"},
        \\    {"op":"event-digest"},
        \\    {"op":"event-kinds","values":["aborted","consumed","prepared"]},
        \\    {"op":"reducer","mode":"retained","event_kind":"/kind",
        \\      "registers":[{"name":"pending","max_bytes":4096}],
        \\      "admissions":[
        \\        {"on":"prepared","requires":[],"forbids":["pending"],"rules":[],"actions":[{"op":"set","register":"pending","input":"event","path":"/body"}]},
        \\        {"on":"consumed","requires":["pending"],"forbids":[],"rules":[
        \\          {"op":"cross-input-equal","input":"event","left_input":"event","left":"/body/capability_digest","right_input":"pending","right":"/capability_digest"},
        \\          {"op":"cross-input-equal","input":"event","left_input":"event","left":"/body/step_id","right_input":"pending","right":"/step_id"}
        \\        ],"actions":[{"op":"clear","register":"pending"}]},
        \\        {"on":"aborted","requires":["pending"],"forbids":[],"rules":[
        \\          {"op":"cross-input-equal","input":"event","left_input":"event","left":"/body/capability_digest","right_input":"pending","right":"/capability_digest"},
        \\          {"op":"cross-input-equal","input":"event","left_input":"event","left":"/body/step_id","right_input":"pending","right":"/step_id"}
        \\        ],"actions":[{"op":"clear","register":"pending"}]}
        \\      ]
        \\    }
        \\  ],
        \\  "identity":{},
        \\  "storage":{"kind":"event-log","slots":{"events":{"path":"example/{stream}/capabilities.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},
        \\  "operations":{
        \\    "abort":{"effects":[{"op":"compare-and-append","slot":"events","input":"abort","event":{"mode":"chained",
        \\      "body_input_field":"body",
        \\      "fields":[{"field":"kind","input_field":"kind"},{"field":"stream_id","input_field":"stream_id"}],
        \\      "body_fields":[{"field":"capability_digest","state_value":{"register":"pending","path":"/capability_digest"}}],
        \\      "forbidden_parameters":["capability"]
        \\    }}]},
        \\    "consume":{"effects":[{"op":"compare-and-append","slot":"events","input":"consume","event":{"mode":"chained",
        \\      "body_input_field":"body",
        \\      "fields":[{"field":"kind","input_field":"kind"},{"field":"stream_id","input_field":"stream_id"}],
        \\      "body_fields":[{"field":"capability_digest","parameter_sha256":{"parameter":"capability","expected_state":{"register":"pending","path":"/capability_digest"}}}]
        \\    }}]},
        \\    "prepare":{"effects":[{"op":"compare-and-append","slot":"events","input":"prepare","event":{"mode":"chained",
        \\      "body_input_field":"body",
        \\      "fields":[{"field":"kind","input_field":"kind"},{"field":"stream_id","input_field":"stream_id"}],
        \\      "generate":[{"name":"capability","op":"secure-token","prefix":"AKC2-","bytes":32}],
        \\      "body_fields":[{"field":"capability_digest","generated_sha256":"capability"}],
        \\      "forbidden_parameters":["capability"]
        \\    }}]}
        \\  },
        \\  "projections":{},
        \\  "bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":8,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}
        \\}
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
    var storage_encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer storage_encoder.deinit();
    try storage.encodeCache(&storage_plan, &storage_encoder);
    const storage_payload = try storage_encoder.toOwnedSlice();
    defer std.testing.allocator.free(storage_payload);
    var storage_decoder = definition_core.cache.Decoder.init(
        storage_payload,
    );
    var cached_storage = try storage.decodeCache(
        std.testing.allocator,
        &storage_decoder,
    );
    defer cached_storage.deinit(std.testing.allocator);
    try storage_decoder.finish();
    try storage.validateCachePlan(&cached_storage, &definition_plan);
    var cached_protocol = (try protocol.compile(
        std.testing.allocator,
        &definition_plan,
        &cached_storage,
    )).?;
    defer cached_protocol.deinit(std.testing.allocator);
    var protocol_plan = (try protocol.compile(
        std.testing.allocator,
        &definition_plan,
        &storage_plan,
    )).?;
    defer protocol_plan.deinit(std.testing.allocator);
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    var base_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "stream", .raw_value = "stream-1" }},
    );
    defer base_parameters.deinit(std.testing.allocator);
    const prepare_input =
        "{\"body\":{\"step_id\":\"step-1\"},\"kind\":\"prepared\",\"stream_id\":\"stream-1\"}";
    var prepared = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        &protocol_plan,
        "prepare",
        repo_root,
        &.{.{ .name = "prepare", .bytes = prepare_input }},
        &base_parameters,
    );
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        @as(usize, 1),
        prepared.generated_outputs.len,
    );
    const raw_capability = prepared.generated_outputs[0].value;
    var wrong_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{
            .{ .name = "capability", .raw_value = "AKC2-wrong" },
            .{ .name = "stream", .raw_value = "stream-1" },
        },
    );
    defer wrong_parameters.deinit(std.testing.allocator);
    const consume_input =
        "{\"body\":{\"step_id\":\"step-1\"},\"kind\":\"consumed\",\"stream_id\":\"stream-1\"}";
    try std.testing.expectError(
        error.EventCapabilityMismatch,
        transact(
            std.testing.allocator,
            &definition_plan,
            &closure,
            "protocol.json",
            &validation_plan,
            &storage_plan,
            &protocol_plan,
            "consume",
            repo_root,
            &.{.{ .name = "consume", .bytes = consume_input }},
            &wrong_parameters,
        ),
    );
    var correct_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{
            .{ .name = "capability", .raw_value = raw_capability },
            .{ .name = "stream", .raw_value = "stream-1" },
        },
    );
    defer correct_parameters.deinit(std.testing.allocator);
    var consumed = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        &protocol_plan,
        "consume",
        repo_root,
        &.{.{ .name = "consume", .bytes = consume_input }},
        &correct_parameters,
    );
    defer consumed.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        @as(usize, 0),
        consumed.generated_outputs.len,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            consumed.returned_content.?,
            raw_capability,
        ) == null,
    );
    const second_prepare_input =
        "{\"body\":{\"step_id\":\"step-2\"},\"kind\":\"prepared\",\"stream_id\":\"stream-1\"}";
    var second_prepared = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        &protocol_plan,
        "prepare",
        repo_root,
        &.{.{ .name = "prepare", .bytes = second_prepare_input }},
        &base_parameters,
    );
    defer second_prepared.deinit(std.testing.allocator);
    const second_digest =
        try definition_core.canonical_json.digestBytesAlloc(
            std.testing.allocator,
            second_prepared.generated_outputs[0].value,
        );
    defer std.testing.allocator.free(second_digest);
    const abort_input =
        "{\"body\":{\"step_id\":\"step-2\"},\"kind\":\"aborted\",\"stream_id\":\"stream-1\"}";
    var aborted = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        &protocol_plan,
        "abort",
        repo_root,
        &.{.{ .name = "abort", .bytes = abort_input }},
        &base_parameters,
    );
    defer aborted.deinit(std.testing.allocator);
    try std.testing.expect(
        std.mem.indexOf(u8, aborted.returned_content.?, second_digest) != null,
    );
    var forbidden_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{
            .{ .name = "capability", .raw_value = raw_capability },
            .{ .name = "stream", .raw_value = "stream-1" },
        },
    );
    defer forbidden_parameters.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ForbiddenEventParameter,
        transact(
            std.testing.allocator,
            &definition_plan,
            &closure,
            "protocol.json",
            &validation_plan,
            &storage_plan,
            &protocol_plan,
            "prepare",
            repo_root,
            &.{.{ .name = "prepare", .bytes = prepare_input }},
            &forbidden_parameters,
        ),
    );
}

test "transaction admits and replays a definition-bound event chain" {
    var definition_tmp = std.testing.tmpDir(.{});
    defer definition_tmp.cleanup();
    try definition_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/chained-events","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["body-digest","compare-and-append","event-digest","event-envelope","event-kinds","exact-object","previous-digest","replay","sequence"]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","input":"event","path":"","keys":["body","body_digest","event_digest","kind","previous_digest","sequence"]},{"op":"event-envelope","input":"event","keys":["body","body_digest","event_digest","kind","previous_digest","sequence"],"sequence":"/sequence","kind":"/kind","previous_digest":"/previous_digest","body":"/body","body_digest":"/body_digest","event_digest":"/event_digest"}]},"constraints":[{"op":"sequence","start":1},{"op":"previous-digest","genesis":null},{"op":"body-digest"},{"op":"event-digest"},{"op":"event-kinds","values":["created","updated"]}],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/chained-events.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},"operations":{"append":{"effects":[{"op":"compare-and-append","slot":"events","input":"event"}]}},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":3,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}}
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
    var protocol_plan = (try protocol.compile(
        std.testing.allocator,
        &definition_plan,
        &storage_plan,
    )).?;
    defer protocol_plan.deinit(std.testing.allocator);
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

    var first_event = try chainedEventAlloc(
        std.testing.allocator,
        1,
        "created",
        null,
        "{\"id\":\"item-1\",\"status\":\"open\"}",
    );
    defer first_event.deinit(std.testing.allocator);
    var first = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        &protocol_plan,
        "append",
        repo_root,
        &.{.{ .name = "event", .bytes = first_event.bytes }},
        &parameters,
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.storage_mutated);

    var second_event = try chainedEventAlloc(
        std.testing.allocator,
        2,
        "updated",
        first_event.digest,
        "{\"id\":\"item-1\",\"status\":\"closed\"}",
    );
    defer second_event.deinit(std.testing.allocator);
    var second = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        &protocol_plan,
        "append",
        repo_root,
        &.{.{ .name = "event", .bytes = second_event.bytes }},
        &parameters,
    );
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second.storage_mutated);

    var broken_event = try chainedEventAlloc(
        std.testing.allocator,
        3,
        "updated",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "{\"id\":\"item-1\",\"status\":\"archived\"}",
    );
    defer broken_event.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.EventPreviousDigestMismatch,
        transact(
            std.testing.allocator,
            &definition_plan,
            &closure,
            "protocol.json",
            &validation_plan,
            &storage_plan,
            &protocol_plan,
            "append",
            repo_root,
            &.{.{ .name = "event", .bytes = broken_event.bytes }},
            &parameters,
        ),
    );

    var resolved_storage = try storage.resolve(
        std.testing.allocator,
        &storage_plan,
        &parameters,
    );
    defer resolved_storage.deinit(std.testing.allocator);
    var snapshot = try custody.readSlot(
        std.testing.allocator,
        repo_root,
        definition_plan.id,
        resolved_storage.slot(protocol_plan.target_slot_index),
    );
    defer snapshot.deinit(std.testing.allocator);
    var stats = try replay.validateSlot(
        std.testing.allocator,
        repo_root,
        definition_plan.id,
        resolved_storage.slot(protocol_plan.target_slot_index),
        &snapshot,
        &parameters,
        definition_plan.bounds.max_records,
        true,
    );
    defer stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), stats.records_validated);
    try std.testing.expectEqual(@as(usize, 2), stats.protocol_state.?.records);
    try std.testing.expectEqualStrings(
        second_event.digest,
        stats.protocol_state.?.previousDigest().?,
    );
    try std.testing.expectError(
        error.HistoricalProtocolBindingMismatch,
        replay.validateSlot(
            std.testing.allocator,
            repo_root,
            definition_plan.id,
            resolved_storage.slot(protocol_plan.target_slot_index),
            &snapshot,
            &parameters,
            definition_plan.bounds.max_records,
            false,
        ),
    );
}

test "document replacements replay from immutable prior revisions" {
    var definition_tmp = std.testing.tmpDir(.{});
    defer definition_tmp.cleanup();
    try definition_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "document.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/document-history","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["compare-and-replace","create-new","exact-object","idempotency-key"]},"parameters":{"request":{"type":"safe_identifier","required":false},"revision":{"type":"digest","required":false}},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","input":"record","path":"","keys":["value"]}]},"constraints":[],"identity":{},"storage":{"kind":"addressed-document","slots":{"current":{"path":"example/current.json","kind":"document","codec":"json","max_bytes":4096}}},"operations":{"create":{"effects":[{"op":"create-new","slot":"current","input":"record"}]},"replace":{"effects":[{"op":"compare-and-replace","slot":"current","input":"record","expected_revision_param":"revision","idempotency_param":"request"}]}},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":10,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &definition_tmp.dir,
        "document.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "document.json",
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
        &.{.{ .name = "request", .raw_value = "replace-once" }},
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

    var created = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "document.json",
        &validation_plan,
        &storage_plan,
        null,
        "create",
        repo_root,
        &.{.{ .name = "record", .bytes = "{\"value\": 1}" }},
        &parameters,
    );
    defer created.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.MissingOperationParameter,
        transact(
            std.testing.allocator,
            &definition_plan,
            &closure,
            "document.json",
            &validation_plan,
            &storage_plan,
            null,
            "replace",
            repo_root,
            &.{.{ .name = "record", .bytes = "{\"value\": 2}" }},
            &parameters,
        ),
    );
    var replace_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{
            .{ .name = "request", .raw_value = "replace-once" },
            .{
                .name = "revision",
                .raw_value = created.effects[0].revision_after,
            },
        },
    );
    defer replace_parameters.deinit(std.testing.allocator);
    var replaced = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "document.json",
        &validation_plan,
        &storage_plan,
        null,
        "replace",
        repo_root,
        &.{.{ .name = "record", .bytes = "{\"value\": 2}" }},
        &replace_parameters,
    );
    defer replaced.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("created", created.effects[0].result);
    try std.testing.expectEqualStrings("replaced", replaced.effects[0].result);
    var duplicate_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{
            .{ .name = "request", .raw_value = "replace-once" },
            .{
                .name = "revision",
                .raw_value = replaced.effects[0].revision_after,
            },
        },
    );
    defer duplicate_parameters.deinit(std.testing.allocator);
    var duplicate = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "document.json",
        &validation_plan,
        &storage_plan,
        null,
        "replace",
        repo_root,
        &.{.{ .name = "record", .bytes = "{\"value\": 2}" }},
        &duplicate_parameters,
    );
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expect(!duplicate.storage_mutated);
    try std.testing.expectEqualStrings(
        "idempotent",
        duplicate.effects[0].result,
    );

    var resolved_storage = try storage.resolve(
        std.testing.allocator,
        &storage_plan,
        &parameters,
    );
    defer resolved_storage.deinit(std.testing.allocator);
    var snapshot = try custody.readSlot(
        std.testing.allocator,
        repo_root,
        definition_plan.id,
        resolved_storage.slot(0),
    );
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.binding.rows.len);
    var stats = try replay.validateSlot(
        std.testing.allocator,
        repo_root,
        definition_plan.id,
        resolved_storage.slot(0),
        &snapshot,
        &parameters,
        definition_plan.bounds.max_records,
        false,
    );
    defer stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), stats.records_validated);
    try std.testing.expectEqual(@as(usize, 1), stats.definition_versions);
    try std.testing.expectEqualStrings("{\"value\":2}", snapshot.content);

    const first_revision_path = try revision_archive.pathAlloc(
        std.testing.allocator,
        repo_root,
        snapshot.binding.rows[1].revision_before.?,
    );
    defer std.testing.allocator.free(first_revision_path);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        first_revision_path,
        "{\"value\":9}",
    );
    try std.testing.expectError(
        error.RevisionArchiveDigestMismatch,
        transact(
            std.testing.allocator,
            &definition_plan,
            &closure,
            "document.json",
            &validation_plan,
            &storage_plan,
            null,
            "replace",
            repo_root,
            &.{.{ .name = "record", .bytes = "{\"value\": 2}" }},
            &duplicate_parameters,
        ),
    );
    try std.testing.expectError(
        error.RevisionArchiveDigestMismatch,
        replay.validateSlot(
            std.testing.allocator,
            repo_root,
            definition_plan.id,
            resolved_storage.slot(0),
            &snapshot,
            &parameters,
            definition_plan.bounds.max_records,
            false,
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
            &closure,
            "protocol.json",
            &validation_plan,
            &storage_plan,
            null,
            "append",
            repo_root,
            &.{.{ .name = "event", .bytes = "{\"kind\":\"new\"}" }},
            &parameters,
        ),
    );
}

test "plain event idempotency derives a transformed truncated digest with an explicit bypass" {
    var definition_tmp = std.testing.tmpDir(.{});
    defer definition_tmp.cleanup();
    try definition_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{
        \\  "schema":"ledger-artifact-definition/v1",
        \\  "id":"example/content-idempotency",
        \\  "owner":"example",
        \\  "requires":{"abi":"ledger-artifact-abi/v1","operators":["bind-existing","canonical-json","compare-and-append","event-materialization","exact-object","idempotency-key","sha1"]},
        \\  "parameters":{"allow_duplicate":{"type":"boolean","required":false,"default":false}},
        \\  "inputs":{"submission":{"codec":"json","max_bytes":4096}},
        \\  "canonicalization":{"steps":[{"op":"canonical-json","input":"submission"}]},
        \\  "shape":{"rules":[
        \\    {"op":"exact-object","input":"submission","path":"","keys":["record"]},
        \\    {"op":"exact-object","input":"submission","path":"/record","keys":["context","status","summary"]},
        \\    {"op":"exact-object","input":"submission","path":"/record/context","keys":["branch","paths","repo"]}
        \\  ]},
        \\  "constraints":[],
        \\  "identity":{},
        \\  "storage":{"kind":"event-log","slots":{"events":{"path":"example/content-idempotency.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},
        \\  "operations":{
        \\    "bind":{"effects":[{"op":"bind-existing","slot":"events","input":"submission","event_from_operation":"capture"}]},
        \\    "capture":{"effects":[{"op":"compare-and-append","slot":"events","input":"submission","event":{
        \\    "mode":"plain",
        \\    "body_input_field":"record",
        \\    "field_order":["event","record"],
        \\    "body_order":["status","summary","context","fingerprint"],
        \\    "object_orders":[{"path":"/context","fields":["repo","branch","paths"]}],
        \\    "escape_non_ascii":true,
        \\    "fields":[{"field":"event","literal":"capture"}],
        \\    "derive":[{"name":"fingerprint","op":"sha1","encoding":"hex","prefix_bytes":16,"fragments":[{"input_text":"/record/status"},{"literal":"|"},{"input_text":"/record/summary","transform":"ascii-lower"}],"max_bytes":4096}],
        \\    "idempotency":{"derived":"fingerprint","bypass_param":"allow_duplicate"},
        \\    "body_fields":[{"field":"fingerprint","derived":"fingerprint"}]
        \\  }}]}
        \\  },
        \\  "projections":{},
        \\  "bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}
        \\}
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
    var compiled_storage = try storage.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer compiled_storage.deinit(std.testing.allocator);
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer encoder.deinit();
    try storage.encodeCache(&compiled_storage, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var storage_plan = try storage.decodeCache(
        std.testing.allocator,
        &decoder,
    );
    defer storage_plan.deinit(std.testing.allocator);
    try decoder.finish();
    try storage.validateCachePlan(&storage_plan, &definition_plan);
    const bind_operation = storage_plan.findOperation("bind") orelse
        return error.TestExpectedBindOperation;
    try std.testing.expect(
        bind_operation.effects[0].event.?.idempotency != null,
    );
    var ordinary = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{},
    );
    defer ordinary.deinit(std.testing.allocator);
    var bypass = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "allow_duplicate", .raw_value = "true" }},
    );
    defer bypass.deinit(std.testing.allocator);
    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    const repo_root = try repo_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    const request =
        "{\"record\":{\"status\":\"do_more\",\"summary\":\"MiXeD CaSe\",\"context\":{\"branch\":\"main\",\"paths\":[],\"repo\":\"café\"}}}";
    var first = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        null,
        "capture",
        repo_root,
        &.{.{ .name = "submission", .bytes = request }},
        &ordinary,
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.storage_mutated);
    try std.testing.expectEqual(@as(usize, 1), first.generated_outputs.len);
    try std.testing.expectEqualStrings(
        "fingerprint",
        first.generated_outputs[0].name,
    );
    try std.testing.expectEqualStrings(
        "eea046b1709337f1",
        first.generated_outputs[0].value,
    );
    try std.testing.expectEqualStrings(
        "{\"event\":\"capture\",\"record\":{\"status\":\"do_more\",\"summary\":\"MiXeD CaSe\",\"context\":{\"repo\":\"caf\\u00E9\",\"branch\":\"main\",\"paths\":[]},\"fingerprint\":\"eea046b1709337f1\"}}",
        first.returned_content.?,
    );
    var duplicate = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        null,
        "capture",
        repo_root,
        &.{.{ .name = "submission", .bytes = request }},
        &ordinary,
    );
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expect(!duplicate.storage_mutated);
    try std.testing.expectEqualStrings(
        "idempotent",
        duplicate.effects[0].result,
    );
    try std.testing.expectEqualStrings(
        first.returned_content.?,
        duplicate.returned_content.?,
    );
    var legacy_tmp = std.testing.tmpDir(.{});
    defer legacy_tmp.cleanup();
    const legacy_root = try legacy_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(legacy_root);
    const legacy_event_path = try std.fs.path.join(
        std.testing.allocator,
        &.{
            legacy_root,
            ".ledger",
            "example",
            "content-idempotency.jsonl",
        },
    );
    defer std.testing.allocator.free(legacy_event_path);
    const legacy_content = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}\n",
        .{first.returned_content.?},
    );
    defer std.testing.allocator.free(legacy_content);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        legacy_event_path,
        legacy_content,
    );
    var binding = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        null,
        "bind",
        legacy_root,
        &.{},
        &ordinary,
    );
    defer binding.deinit(std.testing.allocator);
    try std.testing.expect(binding.storage_mutated);
    try std.testing.expectEqualStrings("bound", binding.effects[0].result);
    var legacy_duplicate = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        null,
        "capture",
        legacy_root,
        &.{.{ .name = "submission", .bytes = request }},
        &ordinary,
    );
    defer legacy_duplicate.deinit(std.testing.allocator);
    try std.testing.expect(!legacy_duplicate.storage_mutated);
    try std.testing.expectEqualStrings(
        first.returned_content.?,
        legacy_duplicate.returned_content.?,
    );
    var allowed = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        null,
        "capture",
        repo_root,
        &.{.{ .name = "submission", .bytes = request }},
        &bypass,
    );
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.storage_mutated);
    var duplicate_after_bypass = try transact(
        std.testing.allocator,
        &definition_plan,
        &closure,
        "protocol.json",
        &validation_plan,
        &storage_plan,
        null,
        "capture",
        repo_root,
        &.{.{ .name = "submission", .bytes = request }},
        &ordinary,
    );
    defer duplicate_after_bypass.deinit(std.testing.allocator);
    try std.testing.expect(!duplicate_after_bypass.storage_mutated);
    try std.testing.expectEqualStrings(
        first.returned_content.?,
        duplicate_after_bypass.returned_content.?,
    );
    const event_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ repo_root, ".ledger", "example", "content-idempotency.jsonl" },
    );
    defer std.testing.allocator.free(event_path);
    const events = try durable_store.readRegularFileNoSymlink(
        std.testing.allocator,
        event_path,
        65536,
    );
    defer std.testing.allocator.free(events);
    var lines = std.mem.splitScalar(u8, events, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len != 0) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
