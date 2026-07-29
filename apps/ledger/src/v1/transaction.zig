const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const definition_archive = @import("definition_archive.zig");
const document = @import("document.zig");
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
    if (!std.fs.path.isAbsolute(repo_root)) {
        return error.RepositoryRootNotAbsolute;
    }
    if (!std.mem.eql(
        u8,
        definition_plan.closure_digest[0..],
        definition_closure.digestSlice(),
    )) {
        return error.DefinitionClosureDigestMismatch;
    }
    const unresolved_operation = storage_plan.findOperation(operation_name) orelse
        return error.UnknownOperation;
    const transaction_generated = try generateDocumentOutputsAlloc(
        allocator,
        storage_plan,
        unresolved_operation,
        repo_root,
        parameters,
    );
    defer deinitGeneratedOutputs(allocator, transaction_generated);
    const generated_values = try documentValueViewsAlloc(
        allocator,
        transaction_generated,
    );
    defer allocator.free(generated_values);
    var resolved_storage = try storage.resolveWithGenerated(
        allocator,
        storage_plan,
        parameters,
        generated_values,
    );
    defer resolved_storage.deinit(allocator);
    const operation = resolved_storage.findOperation(operation_name) orelse
        return error.UnknownOperation;
    return transactResolved(
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
        documents,
        parameters,
        transaction_generated,
    );
}

fn transactResolved(
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
    documents: []const validation.InputDocument,
    parameters: *const definition_core.parameters.Bindings,
    transaction_generated: []const protocol.GeneratedOutput,
) !Result {
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
            storage_plan,
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
        return invalidTransactionResult(
            allocator,
            definition_plan,
            operation_name,
            &execution,
        );
    }
    try validateOperationParameterBindings(
        operation,
        &execution,
        parameters,
    );
    return transactValidated(
        allocator,
        definition_plan,
        definition_closure,
        definition_entry_path,
        storage_plan,
        event_protocol,
        operation,
        operation_name,
        repo_root,
        &execution,
        parameters,
        transaction_generated,
    );
}

const TransactionPaths = struct {
    ledger_root: []u8,
    transactions: []u8,
    bindings: []u8,
    definitions: []u8,
    revisions: []u8,
    created_control_paths: bool,

    fn init(
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        require_revisions: bool,
    ) !TransactionPaths {
        const ledger_root = try std.fs.path.join(
            allocator,
            &.{ repo_root, ".ledger" },
        );
        errdefer allocator.free(ledger_root);
        const paths: TransactionPaths = .{
            .ledger_root = ledger_root,
            .transactions = try std.fs.path.join(
                allocator,
                &.{ ledger_root, ".transactions" },
            ),
            .bindings = undefined,
            .definitions = undefined,
            .revisions = undefined,
            .created_control_paths = false,
        };
        errdefer allocator.free(paths.transactions);
        var initialized = paths;
        initialized.bindings = try std.fs.path.join(
            allocator,
            &.{ ledger_root, ".bindings" },
        );
        errdefer allocator.free(initialized.bindings);
        initialized.definitions = try std.fs.path.join(
            allocator,
            &.{ ledger_root, ".definitions" },
        );
        errdefer allocator.free(initialized.definitions);
        initialized.revisions = try std.fs.path.join(
            allocator,
            &.{ ledger_root, ".revisions" },
        );
        errdefer allocator.free(initialized.revisions);
        initialized.created_control_paths =
            !directoryExists(initialized.ledger_root) or
            !directoryExists(initialized.transactions) or
            !directoryExists(initialized.bindings) or
            !directoryExists(initialized.definitions) or
            (require_revisions and !directoryExists(initialized.revisions));
        try initialized.ensure(allocator, require_revisions);
        return initialized;
    }

    fn ensure(
        self: TransactionPaths,
        allocator: std.mem.Allocator,
        require_revisions: bool,
    ) !void {
        try durable_store.ensureDirectoryPathNoSymlinks(self.ledger_root);
        try durable_store.ensureDirectoryPathNoSymlinks(self.transactions);
        try durable_store.ensureDirectoryPathNoSymlinks(self.bindings);
        try durable_store.ensureDirectoryPathNoSymlinks(self.definitions);
        if (require_revisions) {
            try durable_store.ensureDirectoryPathNoSymlinks(self.revisions);
        }
        try durable_store.recoverAndCompactTransactions(
            allocator,
            self.transactions,
        );
        try durable_store.ensureNoPendingTransactions(
            allocator,
            self.transactions,
        );
    }

    fn deinit(
        self: *TransactionPaths,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.ledger_root);
        allocator.free(self.transactions);
        allocator.free(self.bindings);
        allocator.free(self.definitions);
        allocator.free(self.revisions);
        self.* = undefined;
    }
};

fn directoryExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var directory = std.Io.Dir.openDirAbsolute(io, path, .{}) catch
        return false;
    directory.close(io);
    return true;
}

fn invalidTransactionResult(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    operation_name: []const u8,
    execution: *validation.Execution,
) !Result {
    const owned_operation = try allocator.dupe(u8, operation_name);
    errdefer allocator.free(owned_operation);
    var validation_result = try execution.takeResult(
        allocator,
        definition_plan,
    );
    errdefer validation_result.deinit(allocator);
    const effects = try allocator.alloc(EffectReceipt, 0);
    errdefer allocator.free(effects);
    const generated_outputs =
        try allocator.alloc(protocol.GeneratedOutput, 0);
    return .{
        .validation_result = validation_result,
        .operation = owned_operation,
        .transaction_id = null,
        .effects = effects,
        .returned_content = null,
        .generated_outputs = generated_outputs,
        .storage_mutated = false,
    };
}

fn transactValidated(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    definition_closure: *const definition_core.Closure,
    definition_entry_path: []const u8,
    storage_plan: *const storage.ResolvedPlan,
    event_protocol: ?*const protocol.Plan,
    operation: *const storage.Operation,
    operation_name: []const u8,
    repo_root: []const u8,
    execution: *validation.Execution,
    parameters: *const definition_core.parameters.Bindings,
    transaction_generated: []const protocol.GeneratedOutput,
) !Result {
    last_mutation_state = null;
    var paths = try TransactionPaths.init(
        allocator,
        repo_root,
        operationNeedsRevisionArchive(operation),
    );
    defer paths.deinit(allocator);
    last_mutation_state = paths.created_control_paths;
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
        storage_plan,
        event_protocol,
        operation,
        operation_name,
        repo_root,
        execution,
        parameters,
        transaction_generated,
    );
    defer deinitPreparedEffects(allocator, prepared);
    try validateReturnedContentBound(definition_plan, prepared);
    const duplicate_count = try validateIdempotencyDisposition(
        prepared,
        archive.exists,
    );
    const transaction_id = try commitPreparedEffects(
        allocator,
        storage_plan,
        prepared,
        &archive,
        &paths,
        duplicate_count != 0,
    );
    errdefer if (transaction_id) |value| allocator.free(value);
    return finishTransactionResult(
        allocator,
        definition_plan,
        storage_plan,
        operation_name,
        execution,
        prepared,
        transaction_id,
        duplicate_count != 0,
    );
}

fn validateReturnedContentBound(
    definition_plan: *const definition.Plan,
    prepared: []const PreparedEffect,
) !void {
    if (prepared.len == 1 and
        prepared[0].canonical_input.len >
            definition_plan.bounds.max_output_bytes)
    {
        return error.OutputLimitExceeded;
    }
}

fn deinitPreparedEffects(
    allocator: std.mem.Allocator,
    prepared: []PreparedEffect,
) void {
    for (prepared) |*effect| effect.deinit(allocator);
    allocator.free(prepared);
}

fn validateIdempotencyDisposition(
    prepared: []const PreparedEffect,
    archive_exists: bool,
) !usize {
    var duplicate_count: usize = 0;
    for (prepared) |effect| if (effect.idempotency_match) {
        duplicate_count += 1;
    };
    if (duplicate_count != 0 and duplicate_count != prepared.len) {
        return error.PartialIdempotencyMatch;
    }
    if (duplicate_count != 0 and !archive_exists) {
        return error.DefinitionArchiveMissing;
    }
    return duplicate_count;
}

fn commitPreparedEffects(
    allocator: std.mem.Allocator,
    storage_plan: *const storage.ResolvedPlan,
    prepared: []const PreparedEffect,
    archive: *const definition_archive.Candidate,
    paths: *const TransactionPaths,
    idempotent: bool,
) !?[]u8 {
    if (idempotent) return null;
    const mutations = try buildMutations(
        allocator,
        storage_plan,
        prepared,
        archive,
    );
    defer allocator.free(mutations);
    return try commitMutationsAlloc(
        allocator,
        paths,
        mutations,
    );
}

fn commitMutationsAlloc(
    allocator: std.mem.Allocator,
    paths: *const TransactionPaths,
    mutations: []const durable_store.TransactionMutation,
) ![]u8 {
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ paths.ledger_root, ".fencing.counter" },
    );
    defer allocator.free(counter_path);
    last_mutation_state = null;
    var commit = try durable_store.commitTextTransaction(
        allocator,
        paths.transactions,
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
    return allocator.dupe(u8, commit.transaction_id);
}

fn finishTransactionResult(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.ResolvedPlan,
    operation_name: []const u8,
    execution: *validation.Execution,
    prepared: []const PreparedEffect,
    transaction_id: ?[]u8,
    idempotent: bool,
) !Result {
    const receipts = try buildReceipts(
        allocator,
        storage_plan,
        prepared,
        idempotent,
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
        .storage_mutated = !idempotent,
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
    last_mutation_state = null;
    var paths = try TransactionPaths.init(
        allocator,
        repo_root,
        false,
    );
    defer paths.deinit(allocator);
    last_mutation_state = paths.created_control_paths;
    var archive = try definition_archive.prepare(
        allocator,
        repo_root,
        definition_plan.id,
        definition_entry_path,
        definition_closure,
    );
    defer archive.deinit(allocator);
    const prepared = try prepareExistingBindingsAlloc(
        allocator,
        definition_plan,
        validation_plan,
        storage_plan,
        event_protocol,
        operation,
        operation_name,
        repo_root,
        parameters,
    );
    defer deinitPreparedBindings(allocator, prepared);
    const mutations = try buildExistingBindingMutationsAlloc(
        allocator,
        storage_plan,
        prepared,
        &archive,
    );
    defer allocator.free(mutations);
    const transaction_id = try commitMutationsAlloc(
        allocator,
        &paths,
        mutations,
    );
    errdefer allocator.free(transaction_id);
    return finishBindingResult(
        allocator,
        definition_plan,
        storage_plan,
        operation_name,
        prepared,
        transaction_id,
    );
}

fn prepareExistingBindingsAlloc(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    validation_plan: *const validation.Plan,
    storage_plan: *const storage.ResolvedPlan,
    event_protocol: ?*const protocol.Plan,
    operation: *const storage.Operation,
    operation_name: []const u8,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) ![]PreparedBinding {
    const prepared = try allocator.alloc(PreparedBinding, operation.effects.len);
    var prepared_count: usize = 0;
    errdefer {
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
    return prepared;
}

fn deinitPreparedBindings(
    allocator: std.mem.Allocator,
    prepared: []PreparedBinding,
) void {
    for (prepared) |*item| item.deinit(allocator);
    allocator.free(prepared);
}

fn buildExistingBindingMutationsAlloc(
    allocator: std.mem.Allocator,
    storage_plan: *const storage.ResolvedPlan,
    prepared: []const PreparedBinding,
    archive: *const definition_archive.Candidate,
) ![]durable_store.TransactionMutation {
    const archive_count: usize = if (archive.exists) 0 else 1;
    const mutations = try allocator.alloc(
        durable_store.TransactionMutation,
        prepared.len * 2 + archive_count,
    );
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
    return mutations;
}

fn buildBindingReceiptsAlloc(
    allocator: std.mem.Allocator,
    storage_plan: *const storage.ResolvedPlan,
    prepared: []const PreparedBinding,
) ![]EffectReceipt {
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
    return receipts;
}

fn finishBindingResult(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.ResolvedPlan,
    operation_name: []const u8,
    prepared: []const PreparedBinding,
    transaction_id: []u8,
) !Result {
    const receipts = try buildBindingReceiptsAlloc(
        allocator,
        storage_plan,
        prepared,
    );
    errdefer {
        for (receipts) |*receipt| receipt.deinit(allocator);
        allocator.free(receipts);
    }
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

const ExistingBindingSource = struct {
    slot_path: []u8,
    slot_content: []u8,
    slot_digest: []u8,
    binding_path: []u8,
    before: custody.BindingSnapshot,

    fn deinit(
        self: *ExistingBindingSource,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.slot_path);
        allocator.free(self.slot_content);
        allocator.free(self.slot_digest);
        allocator.free(self.binding_path);
        self.before.deinit(allocator);
        self.* = undefined;
    }
};

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
    var source = try readExistingBindingSource(
        allocator,
        definition_plan,
        slot,
        repo_root,
    );
    errdefer source.deinit(allocator);
    if (source.before.exists) return error.StoreAlreadyBound;
    const record_count = try validateExistingContent(
        allocator,
        definition_plan,
        validation_plan,
        effect,
        slot,
        event_protocol,
        effect.slot_index,
        source.slot_content,
        parameters,
    );
    const binding_after = try custody.appendBindingRowAlloc(
        allocator,
        source.before.bytes,
        definition_plan,
        slot,
        operation_name,
        source.slot_digest,
        source.slot_digest,
        .{
            .kind = .existing_store_binding,
            .record_start = if (record_count) |_| 0 else null,
            .record_end = record_count,
            .extent_start = 0,
            .extent_end = source.slot_content.len,
        },
        null,
        source.slot_digest,
        null,
    );
    source.before.deinit(allocator);
    return .{
        .slot_index = effect.slot_index,
        .input_index = effect.input_index,
        .slot_path = source.slot_path,
        .slot_content = source.slot_content,
        .slot_digest = source.slot_digest,
        .binding_path = source.binding_path,
        .binding_after = binding_after,
    };
}

fn readExistingBindingSource(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    slot: storage.ResolvedSlot,
    repo_root: []const u8,
) !ExistingBindingSource {
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
    errdefer before.deinit(allocator);
    return .{
        .slot_path = slot_path,
        .slot_content = slot_content,
        .slot_digest = slot_digest,
        .binding_path = binding_path,
        .before = before,
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
        try validateEffectParameterBindingsBytes(
            allocator,
            effect,
            content,
            parameters,
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
        return validateExistingMaterializedEvent(
            allocator,
            validation_plan,
            input_name,
            event_protocol,
            protocol_state,
            materialized,
            bytes,
            parameters,
        );
    }
    return validateExistingDirectEvent(
        allocator,
        validation_plan,
        input_name,
        input_index,
        event_protocol,
        protocol_state,
        bytes,
        parameters,
    );
}

fn validateExistingMaterializedEvent(
    allocator: std.mem.Allocator,
    validation_plan: *const validation.Plan,
    input_name: []const u8,
    event_protocol: ?*const protocol.Plan,
    protocol_state: ?*protocol.ReplayState,
    materialized: storage.EventMaterialization,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !void {
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
    const canonical = try canonicalExistingEventAlloc(
        allocator,
        &materialized,
        parsed.value,
    );
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) {
        return error.ExistingStoreValidationFailed;
    }
    const reconstructed = try reconstructExistingEventInputAlloc(
        allocator,
        event_protocol,
        protocol_state,
        &materialized,
        parsed.value,
    );
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
}

fn canonicalExistingEventAlloc(
    allocator: std.mem.Allocator,
    materialized: *const storage.EventMaterialization,
    value: std.json.Value,
) ![]u8 {
    return switch (materialized.mode) {
        .chained => definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            value,
        ),
        .plain => protocol.canonicalPlainStoredEventAlloc(
            allocator,
            materialized,
            value,
        ),
    };
}

fn reconstructExistingEventInputAlloc(
    allocator: std.mem.Allocator,
    event_protocol: ?*const protocol.Plan,
    protocol_state: ?*protocol.ReplayState,
    materialized: *const storage.EventMaterialization,
    value: std.json.Value,
) ![]u8 {
    return switch (materialized.mode) {
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
                materialized,
                value,
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
                protocol_state,
                materialized,
                value,
            );
        },
    };
}

fn validateExistingDirectEvent(
    allocator: std.mem.Allocator,
    validation_plan: *const validation.Plan,
    input_name: []const u8,
    input_index: u8,
    event_protocol: ?*const protocol.Plan,
    protocol_state: ?*protocol.ReplayState,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !void {
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
    std.sort.heap(
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
    transaction_generated: []const protocol.GeneratedOutput,
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
            transaction_generated,
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
    transaction_generated: []const protocol.GeneratedOutput,
) !PreparedEffect {
    const slot = storage_plan.slot(effect.slot_index);
    var source = try EffectSlotSource.init(
        allocator,
        slot,
        effect,
        repo_root,
        parameters,
    );
    errdefer source.deinit(allocator);
    var idempotency = try EffectIdempotency.init(
        allocator,
        definition_plan,
        effect,
        execution,
        parameters,
    );
    defer idempotency.deinit(allocator);
    var binding_before = try readEffectBindingSnapshot(
        allocator,
        definition_plan.id,
        definition_plan.closure_digest[0..],
        slot,
        &source,
        operation_name,
        &idempotency,
    );
    errdefer binding_before.deinit(allocator);
    return prepareEffectWithBinding(
        allocator,
        definition_plan,
        event_protocol,
        effect,
        operation_name,
        repo_root,
        execution,
        parameters,
        transaction_generated,
        slot,
        &source,
        &binding_before,
        &idempotency,
    );
}

fn prepareEffectWithBinding(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    event_protocol: ?*const protocol.Plan,
    effect: storage.Effect,
    operation_name: []const u8,
    repo_root: []const u8,
    execution: *const validation.Execution,
    parameters: *const definition_core.parameters.Bindings,
    transaction_generated: []const protocol.GeneratedOutput,
    slot: storage.ResolvedSlot,
    source: *const EffectSlotSource,
    binding_before: *custody.BindingSnapshot,
    idempotency: *const EffectIdempotency,
) !PreparedEffect {
    var replay_context = try prepareEffectReplay(
        allocator,
        definition_plan,
        event_protocol,
        effect,
        effect.slot_index,
        slot,
        repo_root,
        parameters,
        source,
        binding_before.*,
        idempotency.derived,
    );
    defer replay_context.deinit(allocator);
    return prepareEffectAfterReplay(
        allocator,
        definition_plan,
        event_protocol,
        effect,
        operation_name,
        repo_root,
        execution,
        parameters,
        transaction_generated,
        slot,
        source,
        binding_before,
        &replay_context,
        idempotency.key(),
        idempotency.input_digest,
        replay_context.derived_match,
    );
}

const EffectSlotSource = struct {
    slot_path: []u8,
    binding_path: []u8,
    before: ?[]u8,
    before_digest: ?[]u8,

    fn init(
        allocator: std.mem.Allocator,
        slot: storage.ResolvedSlot,
        effect: storage.Effect,
        repo_root: []const u8,
        parameters: *const definition_core.parameters.Bindings,
    ) !EffectSlotSource {
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
        const before = durable_store.readRegularFileNoSymlink(
            allocator,
            slot_path,
            slot.max_bytes,
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        errdefer if (before) |bytes| allocator.free(bytes);
        const before_digest = if (before) |bytes|
            try definition_core.canonical_json.digestBytesAlloc(
                allocator,
                bytes,
            )
        else
            null;
        errdefer if (before_digest) |digest| allocator.free(digest);
        try validateEffectSlotPreconditions(
            effect,
            before,
            before_digest,
            parameters,
        );
        return .{
            .slot_path = slot_path,
            .binding_path = binding_path,
            .before = before,
            .before_digest = before_digest,
        };
    }

    fn deinit(
        self: *EffectSlotSource,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.slot_path);
        allocator.free(self.binding_path);
        if (self.before) |bytes| allocator.free(bytes);
        if (self.before_digest) |digest| allocator.free(digest);
        self.* = undefined;
    }
};

fn validateEffectSlotPreconditions(
    effect: storage.Effect,
    before: ?[]const u8,
    before_digest: ?[]const u8,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    switch (effect.kind) {
        .create_new => if (before != null) {
            return error.StorageSlotAlreadyExists;
        },
        .compare_append => {},
        .compare_replace => if (before == null) {
            return error.StorageSlotMissing;
        },
        .bind_existing => return error.BindingOperationRequiresMigrationPath,
    }
    if (effect.expected_revision_parameter) |parameter_name| {
        const expected = parameterText(parameters, parameter_name) orelse
            return error.MissingOperationParameter;
        const actual = before_digest orelse return error.RevisionMismatch;
        if (!std.mem.eql(u8, actual, expected)) {
            return error.RevisionMismatch;
        }
    }
}

const EffectIdempotency = struct {
    parameter: ?[]const u8,
    derived: ?[]u8,
    input_digest: []const u8,

    fn init(
        allocator: std.mem.Allocator,
        definition_plan: *const definition.Plan,
        effect: storage.Effect,
        execution: *const validation.Execution,
        parameters: *const definition_core.parameters.Bindings,
    ) !EffectIdempotency {
        const parameter = if (effect.idempotency_parameter) |name|
            parameterText(parameters, name) orelse
                return error.MissingOperationParameter
        else
            null;
        const derived = try deriveEffectIdempotencyKeyAlloc(
            allocator,
            effect,
            execution,
            parameters,
        );
        errdefer if (derived) |value| allocator.free(value);
        const input_digest = execution.inputDigest(
            definition_plan.inputs[effect.input_index].name,
        ) orelse return error.InputDigestMissing;
        return .{
            .parameter = parameter,
            .derived = derived,
            .input_digest = input_digest,
        };
    }

    fn key(self: EffectIdempotency) ?[]const u8 {
        return self.parameter orelse self.derived;
    }

    fn deinit(
        self: *EffectIdempotency,
        allocator: std.mem.Allocator,
    ) void {
        if (self.derived) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn deriveEffectIdempotencyKeyAlloc(
    allocator: std.mem.Allocator,
    effect: storage.Effect,
    execution: *const validation.Execution,
    parameters: *const definition_core.parameters.Bindings,
) !?[]u8 {
    const event = effect.event orelse return null;
    const idempotency = event.idempotency orelse return null;
    const bypass = if (idempotency.bypass_parameter) |name|
        parameterBoolean(parameters, name) orelse
            return error.MissingOperationParameter
    else
        false;
    if (bypass) return null;
    return protocol.derivePlainIdempotencyKeyAlloc(
        allocator,
        &event,
        execution.inputJson(effect.input_index) orelse
            return error.ProtocolInputMustBeJson,
    );
}

fn readEffectBindingSnapshot(
    allocator: std.mem.Allocator,
    definition_id: []const u8,
    definition_digest: []const u8,
    slot: storage.ResolvedSlot,
    source: *const EffectSlotSource,
    operation_name: []const u8,
    idempotency: *const EffectIdempotency,
) !custody.BindingSnapshot {
    var snapshot = try custody.readBindingSnapshot(
        allocator,
        source.binding_path,
        definition_id,
        slot.name,
        slot.relative_path,
        source.before_digest,
        if (idempotency.parameter) |key| .{
            .definition_digest = definition_digest,
            .operation = operation_name,
            .key = key,
            .input_digest = idempotency.input_digest,
        } else null,
    );
    errdefer snapshot.deinit(allocator);
    if (source.before != null and !snapshot.exists) {
        return error.UnboundStore;
    }
    if (source.before == null and snapshot.exists) {
        return error.OrphanedStoreBinding;
    }
    return snapshot;
}

const EffectReplayContext = struct {
    existing_records: ?usize,
    state: ?protocol.ReplayState,
    derived_match: ?[]u8,

    fn deinit(
        self: *EffectReplayContext,
        allocator: std.mem.Allocator,
    ) void {
        if (self.state) |*state| state.deinit(allocator);
        if (self.derived_match) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn prepareEffectReplay(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    event_protocol: ?*const protocol.Plan,
    effect: storage.Effect,
    slot_index: u16,
    slot: storage.ResolvedSlot,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    source: *const EffectSlotSource,
    binding_before: custody.BindingSnapshot,
    derived_key: ?[]const u8,
) !EffectReplayContext {
    const protocol_required = protocolTargetsSlot(
        event_protocol,
        slot_index,
    );
    if (source.before) |content| {
        const snapshot: custody.SlotSnapshot = .{
            .exists = true,
            .path = source.slot_path,
            .content = content,
            .revision = source.before_digest.?,
            .binding = binding_before,
        };
        var derived_observer = try DerivedMatchObserver.init(
            allocator,
            effect,
            derived_key,
        );
        defer derived_observer.deinit();
        var stats = if (derived_observer.active())
            try replay.validateSlotObserved(
                allocator,
                repo_root,
                definition_plan.id,
                slot,
                &snapshot,
                parameters,
                definition_plan.bounds.max_records,
                protocol_required,
                &derived_observer,
            )
        else
            try replay.validateSlot(
                allocator,
                repo_root,
                definition_plan.id,
                slot,
                &snapshot,
                parameters,
                definition_plan.bounds.max_records,
                protocol_required,
            );
        defer stats.deinit(allocator);
        return .{
            .existing_records = if (slot.kind == .event_log)
                stats.records_validated
            else
                null,
            .state = stats.takeProtocolState(),
            .derived_match = derived_observer.takeMatch(),
        };
    }
    return .{
        .existing_records = if (slot.kind == .event_log) 0 else null,
        .state = null,
        .derived_match = null,
    };
}

const DerivedMatchObserver = struct {
    allocator: std.mem.Allocator,
    event: ?storage.EventMaterialization,
    derived_name: ?[]const u8,
    expected: ?[]const u8,
    match: ?[]u8 = null,

    fn init(
        allocator: std.mem.Allocator,
        effect: storage.Effect,
        expected: ?[]const u8,
    ) !DerivedMatchObserver {
        if (expected == null) {
            return .{
                .allocator = allocator,
                .event = null,
                .derived_name = null,
                .expected = null,
            };
        }
        const event = effect.event orelse
            return error.EventIdempotencyRequiresMaterialization;
        const idempotency = event.idempotency orelse
            return error.EventIdempotencyConfigurationMissing;
        return .{
            .allocator = allocator,
            .event = event,
            .derived_name = idempotency.derived,
            .expected = expected,
        };
    }

    fn active(self: DerivedMatchObserver) bool {
        return self.expected != null;
    }

    fn deinit(self: *DerivedMatchObserver) void {
        if (self.match) |value| self.allocator.free(value);
        self.* = undefined;
    }

    fn takeMatch(self: *DerivedMatchObserver) ?[]u8 {
        const result = self.match;
        self.match = null;
        return result;
    }

    pub fn observeReplay(
        self: *DerivedMatchObserver,
        value: std.json.Value,
        raw: []const u8,
        _: ?*const protocol.ReplayState,
    ) !void {
        if (self.match != null) return;
        const event = self.event orelse return;
        const actual = try protocol.storedPlainDerivedValue(
            &event,
            value,
            self.derived_name.?,
        ) orelse return error.EventIdempotencyStoredValueMissing;
        if (!std.mem.eql(u8, actual, self.expected.?)) return;
        self.match = try self.allocator.dupe(u8, raw);
    }
};

fn protocolTargetsSlot(
    event_protocol: ?*const protocol.Plan,
    slot_index: u16,
) bool {
    return event_protocol != null and
        event_protocol.?.target_slot_index == slot_index;
}

fn prepareEffectAfterReplay(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    event_protocol: ?*const protocol.Plan,
    effect: storage.Effect,
    operation_name: []const u8,
    repo_root: []const u8,
    execution: *const validation.Execution,
    parameters: *const definition_core.parameters.Bindings,
    transaction_generated: []const protocol.GeneratedOutput,
    slot: storage.ResolvedSlot,
    source: *const EffectSlotSource,
    binding_before: *const custody.BindingSnapshot,
    replay_context: *EffectReplayContext,
    idempotency_key: ?[]const u8,
    input_digest: []const u8,
    derived_match: ?[]const u8,
) !PreparedEffect {
    const idempotency_match = binding_before.idempotency_match or
        derived_match != null;
    var input = try materializeEffectInputAlloc(
        allocator,
        definition_plan,
        event_protocol,
        effect,
        execution,
        parameters,
        transaction_generated,
        slot,
        source.before,
        binding_before,
        replay_context,
        derived_match,
        idempotency_match,
    );
    errdefer input.deinit(allocator);
    return finishPreparedEffect(
        allocator,
        definition_plan,
        effect,
        operation_name,
        repo_root,
        slot,
        source,
        binding_before,
        replay_context.existing_records,
        idempotency_key,
        input_digest,
        idempotency_match,
        &input,
    );
}

const EffectMaterializedInput = struct {
    canonical: []u8,
    outputs: []protocol.GeneratedOutput,

    fn deinit(
        self: *EffectMaterializedInput,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.canonical);
        deinitGeneratedOutputs(allocator, self.outputs);
        self.* = undefined;
    }
};

fn materializeEffectInputAlloc(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    event_protocol: ?*const protocol.Plan,
    effect: storage.Effect,
    execution: *const validation.Execution,
    parameters: *const definition_core.parameters.Bindings,
    transaction_generated: []const protocol.GeneratedOutput,
    slot: storage.ResolvedSlot,
    before: ?[]const u8,
    binding_before: *const custody.BindingSnapshot,
    replay_context: *EffectReplayContext,
    derived_match: ?[]const u8,
    idempotency_match: bool,
) !EffectMaterializedInput {
    const request = try materialization.canonicalizeInputAlloc(
        allocator,
        execution,
        effect.input_index,
        definition_plan.inputs[effect.input_index].codec,
    );
    defer allocator.free(request);
    if (binding_before.idempotency_match and effect.event != null) {
        return materializeBoundEventInputAlloc(
            allocator,
            before,
            binding_before,
        );
    }
    if (derived_match) |content| {
        return effectInputWithNoOutputs(allocator, content);
    }
    if (effect.event) |*event| {
        return materializeEventEffectInput(
            allocator,
            event_protocol,
            effect.slot_index,
            event,
            execution,
            effect.input_index,
            parameters,
            replay_context,
        );
    }
    if (effect.document) |*document_plan| {
        return materializeDocumentEffectInput(
            allocator,
            definition_plan,
            document_plan,
            execution,
            effect.input_index,
            parameters,
            transaction_generated,
            slot,
            before,
            request,
        );
    }
    return materializeRawEffectInput(
        allocator,
        event_protocol,
        effect.slot_index,
        execution,
        effect.input_index,
        parameters,
        replay_context,
        request,
        idempotency_match,
    );
}

fn materializeBoundEventInputAlloc(
    allocator: std.mem.Allocator,
    before: ?[]const u8,
    binding: *const custody.BindingSnapshot,
) !EffectMaterializedInput {
    const content = before orelse return error.InvalidIdempotencyBinding;
    const match_index = binding.idempotency_match_index orelse
        return error.InvalidIdempotencyBinding;
    const row = binding.rows[match_index];
    if (row.extent_start >= row.extent_end or row.extent_end > content.len) {
        return error.InvalidIdempotencyBinding;
    }
    return effectInputWithNoOutputs(
        allocator,
        content[row.extent_start..row.extent_end],
    );
}

fn effectInputWithNoOutputs(
    allocator: std.mem.Allocator,
    canonical: []const u8,
) !EffectMaterializedInput {
    const content = try allocator.dupe(u8, canonical);
    errdefer allocator.free(content);
    return .{
        .canonical = content,
        .outputs = try allocator.alloc(protocol.GeneratedOutput, 0),
    };
}

fn materializeEventEffectInput(
    allocator: std.mem.Allocator,
    event_protocol: ?*const protocol.Plan,
    slot_index: u16,
    event: *const storage.EventMaterialization,
    execution: *const validation.Execution,
    input_index: u8,
    parameters: *const definition_core.parameters.Bindings,
    replay_context: *EffectReplayContext,
) !EffectMaterializedInput {
    const protocol_required = protocolTargetsSlot(
        event_protocol,
        slot_index,
    );
    var materialized_event = switch (event.mode) {
        .chained => try materializeChainedEffectEvent(
            allocator,
            event_protocol,
            protocol_required,
            event,
            execution,
            input_index,
            parameters,
            replay_context,
        ),
        .plain => try materializePlainEffectEvent(
            allocator,
            event_protocol,
            protocol_required,
            event,
            execution,
            input_index,
            parameters,
            replay_context,
        ),
    };
    errdefer materialized_event.deinit(allocator);
    if (protocol_required) {
        try protocol.admitBound(
            allocator,
            event_protocol.?,
            &replay_context.state.?,
            materialized_event.content,
            parameters,
        );
    }
    const result: EffectMaterializedInput = .{
        .canonical = materialized_event.content,
        .outputs = materialized_event.generated_outputs,
    };
    materialized_event = undefined;
    return result;
}

fn materializeChainedEffectEvent(
    allocator: std.mem.Allocator,
    event_protocol: ?*const protocol.Plan,
    protocol_required: bool,
    event: *const storage.EventMaterialization,
    execution: *const validation.Execution,
    input_index: u8,
    parameters: *const definition_core.parameters.Bindings,
    replay_context: *EffectReplayContext,
) !protocol.MaterializedEvent {
    if (!protocol_required) {
        return error.EventMaterializationRequiresProtocol;
    }
    const current_protocol = event_protocol.?;
    if (current_protocol.mode != .chained) {
        return error.EventMaterializationModeMismatch;
    }
    if (replay_context.state == null) {
        replay_context.state = protocol.ReplayState.init(current_protocol);
    }
    return protocol.materializeEvent(
        allocator,
        current_protocol,
        &replay_context.state.?,
        event,
        execution.inputJson(input_index) orelse
            return error.ProtocolInputMustBeJson,
        parameters,
        currentUnixSeconds(),
        defaultIo(),
    );
}

fn materializePlainEffectEvent(
    allocator: std.mem.Allocator,
    event_protocol: ?*const protocol.Plan,
    protocol_required: bool,
    event: *const storage.EventMaterialization,
    execution: *const validation.Execution,
    input_index: u8,
    parameters: *const definition_core.parameters.Bindings,
    replay_context: *EffectReplayContext,
) !protocol.MaterializedEvent {
    if (protocol_required) {
        const current_protocol = event_protocol.?;
        if (current_protocol.mode != .plain) {
            return error.EventMaterializationModeMismatch;
        }
        if (replay_context.state == null) {
            replay_context.state = protocol.ReplayState.init(
                current_protocol,
            );
        }
    }
    return protocol.materializePlainEvent(
        allocator,
        if (replay_context.state) |*state| state else null,
        event,
        execution.inputJson(input_index) orelse
            return error.ProtocolInputMustBeJson,
        parameters,
        currentUnixSeconds(),
        defaultIo(),
    );
}

fn materializeDocumentEffectInput(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    document_plan: *const document.Plan,
    execution: *const validation.Execution,
    input_index: u8,
    parameters: *const definition_core.parameters.Bindings,
    transaction_generated: []const protocol.GeneratedOutput,
    slot: storage.ResolvedSlot,
    before: ?[]const u8,
    request: []const u8,
) !EffectMaterializedInput {
    const generated_values = try documentValueViewsAlloc(
        allocator,
        transaction_generated,
    );
    defer allocator.free(generated_values);
    const canonical = try document.renderAlloc(
        allocator,
        document_plan,
        request,
        execution.inputJson(input_index),
        before,
        parameters,
        generated_values,
        @min(slot.max_bytes, definition_plan.bounds.max_output_bytes),
    );
    errdefer allocator.free(canonical);
    return .{
        .canonical = canonical,
        .outputs = if (document_plan.identity) |identity|
            try cloneDocumentIdentityOutputsAlloc(
                allocator,
                transaction_generated,
                identity,
            )
        else
            try allocator.alloc(protocol.GeneratedOutput, 0),
    };
}

fn cloneDocumentIdentityOutputsAlloc(
    allocator: std.mem.Allocator,
    outputs: []const protocol.GeneratedOutput,
    identity: document.Identity,
) ![]protocol.GeneratedOutput {
    var names = [_][]const u8{
        identity.name,
        identity.timestamp_name,
        "",
    };
    const count: usize = if (identity.path_name) |path_name| count: {
        names[2] = path_name;
        break :count 3;
    } else 2;
    return cloneNamedGeneratedOutputsAlloc(
        allocator,
        outputs,
        names[0..count],
    );
}

fn materializeRawEffectInput(
    allocator: std.mem.Allocator,
    event_protocol: ?*const protocol.Plan,
    slot_index: u16,
    execution: *const validation.Execution,
    input_index: u8,
    parameters: *const definition_core.parameters.Bindings,
    replay_context: *EffectReplayContext,
    request: []const u8,
    idempotency_match: bool,
) !EffectMaterializedInput {
    const result = try effectInputWithNoOutputs(allocator, request);
    errdefer {
        var owned = result;
        owned.deinit(allocator);
    }
    if (protocolTargetsSlot(event_protocol, slot_index) and
        !idempotency_match)
    {
        const current_protocol = event_protocol.?;
        if (replay_context.state == null) {
            replay_context.state = protocol.ReplayState.init(
                current_protocol,
            );
        }
        try protocol.admitValueBound(
            allocator,
            current_protocol,
            &replay_context.state.?,
            execution.inputJson(input_index) orelse
                return error.ProtocolInputMustBeJson,
            parameters,
        );
    }
    return result;
}

fn finishPreparedEffect(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    effect: storage.Effect,
    operation_name: []const u8,
    repo_root: []const u8,
    slot: storage.ResolvedSlot,
    source: *const EffectSlotSource,
    binding_before: *const custody.BindingSnapshot,
    existing_records: ?usize,
    idempotency_key: ?[]const u8,
    input_digest: []const u8,
    idempotency_match: bool,
    input: *const EffectMaterializedInput,
) !PreparedEffect {
    const canonical_digest =
        try definition_core.canonical_json.digestBytesAlloc(
            allocator,
            input.canonical,
        );
    defer allocator.free(canonical_digest);
    const slot_after = try prepareSlotAfter(
        allocator,
        definition_plan,
        effect,
        slot,
        source,
        existing_records,
        input.canonical,
        idempotency_match,
    );
    errdefer allocator.free(slot_after.bytes);
    errdefer allocator.free(slot_after.digest);
    var revision = try prepareEffectRevision(
        allocator,
        effect,
        slot,
        source,
        binding_before,
        repo_root,
    );
    errdefer if (revision) |*candidate| candidate.deinit(allocator);
    const binding_after = try prepareEffectBindingAfter(
        allocator,
        definition_plan,
        operation_name,
        slot,
        source,
        binding_before,
        input_digest,
        canonical_digest,
        &slot_after,
        idempotency_key,
        idempotency_match,
    );
    return assembledPreparedEffect(
        effect,
        source,
        binding_before,
        &slot_after,
        binding_after,
        input,
        revision,
        idempotency_match,
    );
}

fn assembledPreparedEffect(
    effect: storage.Effect,
    source: *const EffectSlotSource,
    binding_before: *const custody.BindingSnapshot,
    slot_after: *const SlotAfter,
    binding_after: []u8,
    input: *const EffectMaterializedInput,
    revision: ?revision_archive.Candidate,
    idempotency_match: bool,
) PreparedEffect {
    return .{
        .slot_index = effect.slot_index,
        .kind = effect.kind,
        .slot_path = source.slot_path,
        .binding_path = source.binding_path,
        .slot_before = source.before,
        .slot_before_digest = source.before_digest,
        .slot_after = slot_after.bytes,
        .slot_after_digest = slot_after.digest,
        .binding_before = binding_before.*,
        .binding_after = binding_after,
        .canonical_input = input.canonical,
        .generated_outputs = input.outputs,
        .revision_archive = revision,
        .idempotency_match = idempotency_match,
    };
}

fn prepareSlotAfter(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    effect: storage.Effect,
    slot: storage.ResolvedSlot,
    source: *const EffectSlotSource,
    existing_records: ?usize,
    canonical_input: []const u8,
    idempotency_match: bool,
) !SlotAfter {
    if (idempotency_match) {
        const prior = source.before orelse
            return error.InvalidIdempotencyBinding;
        const prior_digest = source.before_digest orelse
            return error.InvalidIdempotencyBinding;
        const bytes = try allocator.dupe(u8, prior);
        errdefer allocator.free(bytes);
        return .{
            .bytes = bytes,
            .digest = try allocator.dupe(u8, prior_digest),
            .extent = null,
        };
    }
    const content = try slotContentAfter(
        allocator,
        slot,
        effect.kind,
        source.before,
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
    return .{
        .bytes = content.bytes,
        .digest = digest,
        .extent = content.extent,
    };
}

fn prepareEffectRevision(
    allocator: std.mem.Allocator,
    effect: storage.Effect,
    slot: storage.ResolvedSlot,
    source: *const EffectSlotSource,
    binding_before: *const custody.BindingSnapshot,
    repo_root: []const u8,
) !?revision_archive.Candidate {
    if (effect.kind != .compare_replace) return null;
    if (binding_before.idempotency_match) {
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
        allocator.free(prior_content);
        return null;
    }
    return try revision_archive.prepare(
        allocator,
        repo_root,
        source.before_digest.?,
        source.before.?,
        slot.max_bytes,
    );
}

fn prepareEffectBindingAfter(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    operation_name: []const u8,
    slot: storage.ResolvedSlot,
    source: *const EffectSlotSource,
    binding_before: *const custody.BindingSnapshot,
    input_digest: []const u8,
    canonical_digest: []const u8,
    slot_after: *const SlotAfter,
    idempotency_key: ?[]const u8,
    idempotency_match: bool,
) ![]u8 {
    if (idempotency_match) {
        return allocator.dupe(u8, binding_before.bytes);
    }
    return custody.appendBindingRowAlloc(
        allocator,
        binding_before.bytes,
        definition_plan,
        slot,
        operation_name,
        input_digest,
        canonical_digest,
        slot_after.extent.?,
        source.before_digest,
        slot_after.digest,
        idempotency_key,
    );
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
    std.sort.heap(
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

fn generateDocumentOutputsAlloc(
    allocator: std.mem.Allocator,
    storage_plan: *const storage.Plan,
    operation: *const storage.Operation,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) ![]protocol.GeneratedOutput {
    var outputs: std.ArrayList(protocol.GeneratedOutput) = .empty;
    errdefer {
        for (outputs.items) |*output| output.deinit(allocator);
        outputs.deinit(allocator);
    }
    const now_ns: i128 = @intCast(
        std.Io.Clock.real.now(defaultIo()).nanoseconds,
    );
    for (operation.effects) |effect| {
        const document_plan = effect.document orelse continue;
        const identity = document_plan.identity orelse continue;
        try appendDocumentIdentityOutputs(
            allocator,
            storage_plan,
            effect.slot_index,
            identity,
            repo_root,
            parameters,
            now_ns,
            &outputs,
        );
    }
    return outputs.toOwnedSlice(allocator);
}

const DocumentIdentitySelection = struct {
    id: ?[]u8,
    timestamp: ?[]u8,
    path: ?[]u8,

    fn deinit(
        self: *DocumentIdentitySelection,
        allocator: std.mem.Allocator,
    ) void {
        if (self.id) |value| allocator.free(value);
        if (self.timestamp) |value| allocator.free(value);
        if (self.path) |value| allocator.free(value);
        self.* = undefined;
    }
};

const DocumentIdentityCandidate = struct {
    id: []u8,
    path: ?[]u8,
};

fn appendDocumentIdentityOutputs(
    allocator: std.mem.Allocator,
    storage_plan: *const storage.Plan,
    slot_index: u16,
    identity: document.Identity,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    now_ns: i128,
    outputs: *std.ArrayList(protocol.GeneratedOutput),
) !void {
    try validateGeneratedIdentityRequest(identity, parameters, outputs.items);
    var selected = try selectDocumentIdentityAlloc(
        allocator,
        storage_plan,
        slot_index,
        identity,
        repo_root,
        parameters,
        outputs.items,
        now_ns,
    );
    defer selected.deinit(allocator);
    try appendSelectedOutput(
        allocator,
        outputs,
        identity.name,
        &selected.id,
    );
    try appendSelectedOutput(
        allocator,
        outputs,
        identity.timestamp_name,
        &selected.timestamp,
    );
    if (identity.path_name) |path_name| {
        try appendSelectedOutput(
            allocator,
            outputs,
            path_name,
            &selected.path,
        );
    }
}

fn validateGeneratedIdentityRequest(
    identity: document.Identity,
    parameters: *const definition_core.parameters.Bindings,
    outputs: []const protocol.GeneratedOutput,
) !void {
    if (parameters.find(identity.name) != null or
        (identity.path_name != null and
            parameters.find(identity.path_name.?) != null))
    {
        return error.GeneratedPathParameterCannotBeSupplied;
    }
    for (outputs) |output| {
        if (std.mem.eql(u8, output.name, identity.name) or
            std.mem.eql(u8, output.name, identity.timestamp_name))
        {
            return error.DuplicateGeneratedOutput;
        }
    }
}

fn selectDocumentIdentityAlloc(
    allocator: std.mem.Allocator,
    storage_plan: *const storage.Plan,
    slot_index: u16,
    identity: document.Identity,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    prior_outputs: []const protocol.GeneratedOutput,
    now_ns: i128,
) !DocumentIdentitySelection {
    const timestamp = try document.rfc3339NanosecondTimestampAlloc(
        allocator,
        now_ns,
    );
    errdefer allocator.free(timestamp);
    var ordinal: u32 = 0;
    while (ordinal <= identity.max_ordinal) : (ordinal += 1) {
        const candidate = try availableDocumentIdentityCandidate(
            allocator,
            storage_plan,
            slot_index,
            identity,
            repo_root,
            parameters,
            prior_outputs,
            timestamp,
            now_ns,
            ordinal,
        ) orelse continue;
        return .{
            .id = candidate.id,
            .timestamp = timestamp,
            .path = candidate.path,
        };
    }
    return error.TimestampOrdinalExhausted;
}

fn availableDocumentIdentityCandidate(
    allocator: std.mem.Allocator,
    storage_plan: *const storage.Plan,
    slot_index: u16,
    identity: document.Identity,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    prior_outputs: []const protocol.GeneratedOutput,
    timestamp: []const u8,
    now_ns: i128,
    ordinal: u32,
) !?DocumentIdentityCandidate {
    const candidate = try document.timestampOrdinalIdAlloc(
        allocator,
        identity,
        now_ns,
        ordinal,
    );
    errdefer allocator.free(candidate);
    const path = if (identity.path_name != null)
        try document.pathComponentAlloc(allocator, identity, candidate)
    else
        null;
    errdefer if (path) |value| allocator.free(value);
    const exists = try documentIdentityPathExists(
        allocator,
        storage_plan,
        slot_index,
        identity,
        repo_root,
        parameters,
        prior_outputs,
        candidate,
        timestamp,
        path,
    );
    if (!exists) return .{ .id = candidate, .path = path };
    allocator.free(candidate);
    if (path) |value| allocator.free(value);
    return null;
}

fn documentIdentityPathExists(
    allocator: std.mem.Allocator,
    storage_plan: *const storage.Plan,
    slot_index: u16,
    identity: document.Identity,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    prior_outputs: []const protocol.GeneratedOutput,
    candidate: []const u8,
    timestamp: []const u8,
    path: ?[]const u8,
) !bool {
    const prior_views = try documentValueViewsAlloc(allocator, prior_outputs);
    defer allocator.free(prior_views);
    var temporary = [_]document.Value{
        .{ .name = identity.name, .value = candidate },
        .{ .name = identity.timestamp_name, .value = timestamp },
        .{ .name = identity.path_name orelse "", .value = path orelse "" },
    };
    const temporary_count: usize = if (identity.path_name != null) 3 else 2;
    const values = try allocator.alloc(
        document.Value,
        prior_views.len + temporary_count,
    );
    defer allocator.free(values);
    @memcpy(values[0..prior_views.len], prior_views);
    @memcpy(values[prior_views.len..], temporary[0..temporary_count]);
    const relative_path = try storage.resolveSlotPathAlloc(
        allocator,
        storage_plan.slots[slot_index],
        parameters,
        values,
    );
    defer allocator.free(relative_path);
    const absolute_path = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", relative_path },
    );
    defer allocator.free(absolute_path);
    const stat = std.Io.Dir.cwd().statFile(
        defaultIo(),
        absolute_path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.SymlinkStorageSlot;
    return true;
}

fn appendSelectedOutput(
    allocator: std.mem.Allocator,
    outputs: *std.ArrayList(protocol.GeneratedOutput),
    name: []const u8,
    value: *?[]u8,
) !void {
    const owned_value = value.* orelse
        return error.GeneratedPathComponentMissing;
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try outputs.append(allocator, .{
        .name = owned_name,
        .value = owned_value,
    });
    value.* = null;
}

fn documentValueViewsAlloc(
    allocator: std.mem.Allocator,
    outputs: []const protocol.GeneratedOutput,
) ![]document.Value {
    const values = try allocator.alloc(document.Value, outputs.len);
    for (outputs, 0..) |output, index| {
        values[index] = .{ .name = output.name, .value = output.value };
    }
    return values;
}

fn cloneNamedGeneratedOutputsAlloc(
    allocator: std.mem.Allocator,
    outputs: []const protocol.GeneratedOutput,
    names: []const []const u8,
) ![]protocol.GeneratedOutput {
    const cloned = try allocator.alloc(protocol.GeneratedOutput, names.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*output| output.deinit(allocator);
        allocator.free(cloned);
    }
    for (names, 0..) |name, index| {
        const source = for (outputs) |output| {
            if (std.mem.eql(u8, output.name, name)) break output;
        } else return error.GeneratedOutputMissing;
        cloned[index] = .{
            .name = try allocator.dupe(u8, source.name),
            .value = try allocator.dupe(u8, source.value),
        };
        initialized += 1;
    }
    return cloned;
}

fn deinitGeneratedOutputs(
    allocator: std.mem.Allocator,
    outputs: []protocol.GeneratedOutput,
) void {
    for (outputs) |*output| output.deinit(allocator);
    allocator.free(outputs);
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

fn validateOperationParameterBindings(
    operation: *const storage.Operation,
    execution: *const validation.Execution,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    for (operation.effects) |effect| {
        if (effect.parameter_bindings.len == 0) continue;
        const input = execution.inputJson(effect.input_index) orelse
            return error.EffectParameterBindingRequiresJsonInput;
        try validateEffectParameterBindingsValue(
            effect,
            input,
            parameters,
        );
    }
}

fn validateEffectParameterBindingsBytes(
    allocator: std.mem.Allocator,
    effect: storage.Effect,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    if (effect.parameter_bindings.len == 0) return;
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
    try validateEffectParameterBindingsValue(
        effect,
        parsed.value,
        parameters,
    );
}

fn validateEffectParameterBindingsValue(
    effect: storage.Effect,
    input: std.json.Value,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    for (effect.parameter_bindings) |binding| {
        const expected = parameterText(parameters, binding.parameter) orelse
            return error.MissingOperationParameter;
        const value = definition_core.json_pointer.lookup(
            input,
            binding.input_pointer,
        ) orelse return error.EffectParameterBindingValueMissing;
        if (value != .string or
            !std.mem.eql(u8, expected, value.string))
        {
            return error.EffectParameterBindingMismatch;
        }
    }
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

const TransactionTestPlans = struct {
    definition_tmp: std.testing.TmpDir,
    closure: definition_core.closure.Closure,
    definition_plan: definition.Plan,
    validation_plan: validation.Plan,
    storage_plan: storage.Plan,
    repo_tmp: std.testing.TmpDir,
    repo_root: [:0]u8,
    entry_path: []const u8,

    fn init(
        source: []const u8,
        entry_path: []const u8,
    ) !TransactionTestPlans {
        var definition_tmp = std.testing.tmpDir(.{});
        errdefer definition_tmp.cleanup();
        try definition_tmp.dir.writeFile(std.testing.io, .{
            .sub_path = entry_path,
            .data = source,
        });
        var closure = try definition_core.closure.loadFromDir(
            std.testing.allocator,
            &definition_tmp.dir,
            entry_path,
            .{},
        );
        errdefer closure.deinit(std.testing.allocator);
        var definition_plan = try definition.compile(
            std.testing.allocator,
            &closure,
            entry_path,
        );
        errdefer definition_plan.deinit(std.testing.allocator);
        var validation_plan = try validation.compile(
            std.testing.allocator,
            &definition_plan,
        );
        errdefer validation_plan.deinit(std.testing.allocator);
        var storage_plan = try storage.compile(
            std.testing.allocator,
            &definition_plan,
        );
        errdefer storage_plan.deinit(std.testing.allocator);
        var repo_tmp = std.testing.tmpDir(.{});
        errdefer repo_tmp.cleanup();
        const repo_root = try repo_tmp.dir.realPathFileAlloc(
            std.testing.io,
            ".",
            std.testing.allocator,
        );
        return .{
            .definition_tmp = definition_tmp,
            .closure = closure,
            .definition_plan = definition_plan,
            .validation_plan = validation_plan,
            .storage_plan = storage_plan,
            .repo_tmp = repo_tmp,
            .repo_root = repo_root,
            .entry_path = entry_path,
        };
    }

    fn deinit(self: *TransactionTestPlans) void {
        std.testing.allocator.free(self.repo_root);
        self.repo_tmp.cleanup();
        self.storage_plan.deinit(std.testing.allocator);
        self.validation_plan.deinit(std.testing.allocator);
        self.definition_plan.deinit(std.testing.allocator);
        self.closure.deinit(std.testing.allocator);
        self.definition_tmp.cleanup();
        self.* = undefined;
    }

    fn bind(
        self: *const TransactionTestPlans,
        raw: []const definition_core.parameters.Input,
    ) !definition_core.parameters.Bindings {
        return definition_core.parameters.bind(
            std.testing.allocator,
            &self.definition_plan.parameter_declarations,
            raw,
        );
    }

    fn execute(
        self: *const TransactionTestPlans,
        event_protocol: ?*const protocol.Plan,
        operation: []const u8,
        documents: []const validation.InputDocument,
        parameters: *const definition_core.parameters.Bindings,
    ) !Result {
        return transact(
            std.testing.allocator,
            &self.definition_plan,
            &self.closure,
            self.entry_path,
            &self.validation_plan,
            &self.storage_plan,
            event_protocol,
            operation,
            self.repo_root,
            documents,
            parameters,
        );
    }
};

const basic_event_definition =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/events\",\"owner\":\"example\",\"requires\":{" ++
    "\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"atomic-transaction\",\"compare-and-append\",\"exact-object\"," ++
    "\"idempotency-key\"]},\"parameters\":{\"request\":{" ++
    "\"type\":\"safe_identifier\",\"required\":true}},\"inputs\":{" ++
    "\"event\":{\"codec\":\"json\",\"max_bytes\":4096}}," ++
    "\"canonicalization\":{},\"shape\":{\"documents\":{\"event\":{" ++
    "\"object\":\"exact\",\"fields\":{\"kind\":{},\"value\":{}}}}}," ++
    "\"constraints\":{\"laws\":[]},\"identity\":{}," ++
    "\"storage\":{\"kind\":\"event-log\",\"slots\":{\"events\":{" ++
    "\"path\":\"example/events.jsonl\",\"codec\":\"jsonl\"," ++
    "\"max_bytes\":65536}}},\"operations\":{\"append\":{" ++
    "\"op\":\"atomic-transaction\",\"effects\":[{" ++
    "\"op\":\"compare-and-append\",\"slot\":\"events\",\"input\":\"event\"," ++
    "\"idempotency_param\":\"request\"}]}},\"projections\":{}," ++
    "\"bounds\":{\"max_input_bytes\":4096,\"max_store_bytes\":65536," ++
    "\"max_records\":2,\"max_output_bytes\":4096,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":16}}";

const BasicAppendResults = struct {
    first: Result,
    second: Result,

    fn deinit(
        self: *BasicAppendResults,
        allocator: std.mem.Allocator,
    ) void {
        self.second.deinit(allocator);
        self.first.deinit(allocator);
        self.* = undefined;
    }
};

fn appendBasicEvents(
    plans: *const TransactionTestPlans,
    first_parameters: *const definition_core.parameters.Bindings,
    second_parameters: *const definition_core.parameters.Bindings,
) !BasicAppendResults {
    var first = try plans.execute(
        null,
        "append",
        &.{.{ .name = "event", .bytes = "{\"kind\":\"one\",\"value\":1}" }},
        first_parameters,
    );
    errdefer first.deinit(std.testing.allocator);
    try std.testing.expect(first.storage_mutated);
    try std.testing.expect(lastMutationState().?);
    try std.testing.expect(!first.semantic_authority_granted);
    try std.testing.expectEqualStrings("appended", first.effects[0].result);
    var second = try plans.execute(
        null,
        "append",
        &.{.{ .name = "event", .bytes = "{\"kind\":\"two\",\"value\":2}" }},
        second_parameters,
    );
    errdefer second.deinit(std.testing.allocator);
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
    return .{ .first = first, .second = second };
}

fn expectBasicEventBytesAndDuplicate(
    plans: *const TransactionTestPlans,
    second_parameters: *const definition_core.parameters.Bindings,
    results: *const BasicAppendResults,
) !void {
    const event_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ plans.repo_root, ".ledger", "example", "events.jsonl" },
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
    var duplicate = try plans.execute(
        null,
        "append",
        &.{.{ .name = "event", .bytes = "{\"kind\":\"two\",\"value\":2}" }},
        second_parameters,
    );
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expect(!duplicate.storage_mutated);
    try std.testing.expect(!lastMutationState().?);
    try std.testing.expectEqualStrings(
        "idempotent",
        duplicate.effects[0].result,
    );
    try std.testing.expectEqualStrings(
        results.second.effects[0].revision_after,
        duplicate.effects[0].revision_after,
    );
}

fn expectBasicBoundsAndBinding(
    plans: *const TransactionTestPlans,
    first_parameters: *const definition_core.parameters.Bindings,
    third_parameters: *const definition_core.parameters.Bindings,
    results: *const BasicAppendResults,
) !void {
    try std.testing.expectError(
        error.TransactionRecordBoundsExceeded,
        plans.execute(
            null,
            "append",
            &.{.{
                .name = "event",
                .bytes = "{\"kind\":\"three\",\"value\":3}",
            }},
            third_parameters,
        ),
    );
    try std.testing.expect(!lastMutationState().?);
    var resolved = try storage.resolve(
        std.testing.allocator,
        &plans.storage_plan,
        first_parameters,
    );
    defer resolved.deinit(std.testing.allocator);
    var snapshot = try custody.readSlot(
        std.testing.allocator,
        plans.repo_root,
        plans.definition_plan.id,
        resolved.slot(0),
    );
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.CurrentStoreRecordBoundsExceeded,
        replay.validateSlot(
            std.testing.allocator,
            plans.repo_root,
            plans.definition_plan.id,
            resolved.slot(0),
            &snapshot,
            first_parameters,
            1,
            false,
        ),
    );
    try expectBasicBindingDefinitionMismatch(plans, results);
}

fn expectBasicBindingDefinitionMismatch(
    plans: *const TransactionTestPlans,
    results: *const BasicAppendResults,
) !void {
    const binding_path = try custody.bindingPathAlloc(
        std.testing.allocator,
        plans.repo_root,
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
            results.second.effects[0].revision_after,
            null,
        ),
    );
}

fn expectBasicPendingRecovery(
    plans: *const TransactionTestPlans,
    third_parameters: *const definition_core.parameters.Bindings,
) !void {
    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ plans.repo_root, ".ledger", ".transactions" },
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
        plans.execute(
            null,
            "append",
            &.{.{
                .name = "event",
                .bytes = "{\"kind\":\"three\",\"value\":3}",
            }},
            third_parameters,
        ),
    );
}

test "transaction appends an event and binding in one durable transaction" {
    var plans = try TransactionTestPlans.init(
        basic_event_definition,
        "protocol.json",
    );
    defer plans.deinit();
    var first_parameters = try plans.bind(
        &.{.{ .name = "request", .raw_value = "first" }},
    );
    defer first_parameters.deinit(std.testing.allocator);
    var second_parameters = try plans.bind(
        &.{.{ .name = "request", .raw_value = "second" }},
    );
    defer second_parameters.deinit(std.testing.allocator);
    var third_parameters = try plans.bind(
        &.{.{ .name = "request", .raw_value = "third" }},
    );
    defer third_parameters.deinit(std.testing.allocator);
    var results = try appendBasicEvents(
        &plans,
        &first_parameters,
        &second_parameters,
    );
    defer results.deinit(std.testing.allocator);
    try expectBasicEventBytesAndDuplicate(
        &plans,
        &second_parameters,
        &results,
    );
    try expectBasicBoundsAndBinding(
        &plans,
        &first_parameters,
        &third_parameters,
        &results,
    );
    try expectBasicPendingRecovery(&plans, &third_parameters);
}

const chained_genesis_digest =
    "sha256:0000000000000000000000000000000000000000000000000000000000000000";
const chained_event_definition =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/materialized-events\",\"owner\":\"example\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"body-digest\",\"canonical-json\",\"compare-and-append\"," ++
    "\"event-digest\",\"event-envelope\",\"event-kinds\"," ++
    "\"event-materialization\",\"exact-object\",\"idempotency-key\"," ++
    "\"previous-digest\",\"replay\",\"secure-token\",\"sequence\"," ++
    "\"sha256\"]},\"parameters\":{\"request\":{" ++
    "\"type\":\"safe_identifier\",\"required\":true}},\"inputs\":{" ++
    "\"request\":{\"codec\":\"json\",\"max_bytes\":4096}}," ++
    "\"canonicalization\":{\"steps\":[{\"op\":\"canonical-json\"," ++
    "\"input\":\"request\"}]},\"shape\":{\"documents\":{\"request\":{" ++
    "\"object\":\"exact\",\"fields\":{\"body\":{},\"content_ref\":{}," ++
    "\"kind\":{},\"predecessor_ref\":{},\"stream_id\":{}}," ++
    "\"event_envelope\":{\"keys\":[\"body\",\"body_digest\",\"content_ref\",\"event_digest\"," ++
    "\"event_id\",\"kind\",\"predecessor_ref\",\"previous_digest\"," ++
    "\"recorded_at\",\"schema\",\"sequence\",\"stream_id\"]," ++
    "\"sequence\":\"/sequence\",\"kind\":\"/kind\"," ++
    "\"previous_digest\":\"/previous_digest\",\"body\":\"/body\"," ++
    "\"body_digest\":\"/body_digest\",\"event_digest\":\"/event_digest\"}}}}," ++
    "\"constraints\":{\"event_log\":{\"start\":1,\"genesis\":\"" ++
    chained_genesis_digest ++ "\",\"kinds\":[\"created\",\"updated\"]}}," ++
    "\"identity\":{},\"storage\":{\"kind\":\"event-log\",\"slots\":{" ++
    "\"events\":{\"path\":\"example/materialized-events.jsonl\"," ++
    "\"kind\":\"event-log\",\"codec\":\"jsonl\",\"max_bytes\":65536}}}," ++
    "\"operations\":{\"append\":{\"effects\":[{" ++
    "\"op\":\"compare-and-append\",\"slot\":\"events\",\"input\":\"request\"," ++
    "\"idempotency_param\":\"request\",\"event\":{\"mode\":\"chained\"," ++
    "\"body_input_field\":\"body\",\"fields\":[{" ++
    "\"field\":\"content_ref\",\"input_field\":\"content_ref\"},{" ++
    "\"field\":\"event_id\",\"sequence_text_prefix\":\"e-\"},{" ++
    "\"field\":\"kind\",\"input_field\":\"kind\"},{" ++
    "\"field\":\"predecessor_ref\",\"input_field\":\"predecessor_ref\"},{" ++
    "\"field\":\"recorded_at\",\"unix_seconds\":true},{" ++
    "\"field\":\"schema\",\"literal\":\"example-event/v1\"},{" ++
    "\"field\":\"stream_id\",\"input_field\":\"stream_id\"}]," ++
    "\"generate\":[{\"name\":\"capability\",\"op\":\"secure-token\"," ++
    "\"prefix\":\"TOK-\",\"bytes\":32}],\"body_fields\":[{" ++
    "\"field\":\"capability_digest\",\"generated_sha256\":\"capability\"}]}}]}}," ++
    "\"projections\":{},\"bounds\":{\"max_input_bytes\":4096," ++
    "\"max_store_bytes\":65536,\"max_records\":3,\"max_output_bytes\":4096," ++
    "\"max_diagnostics\":8,\"max_reducer_states\":4}}";

const first_chained_request =
    "{\"body\":{\"id\":\"item-1\"},\"content_ref\":null," ++
    "\"kind\":\"created\",\"predecessor_ref\":null," ++
    "\"stream_id\":\"stream-1\"}";
const chained_content_ref =
    "sha256:2222222222222222222222222222222222222222222222222222222222222222";
const chained_predecessor_ref =
    "sha256:1111111111111111111111111111111111111111111111111111111111111111";
const second_chained_request =
    "{\"body\":{\"id\":\"item-1\"}," ++
    "\"content_ref\":\"" ++ chained_content_ref ++ "\",\"kind\":\"updated\"," ++
    "\"predecessor_ref\":\"" ++ chained_predecessor_ref ++ "\"," ++
    "\"stream_id\":\"stream-1\"}";

fn cachedProtocolPlan(
    plans: *const TransactionTestPlans,
) !protocol.Plan {
    var cached_storage = try cachedStoragePlan(plans);
    defer cached_storage.deinit(std.testing.allocator);
    return (try protocol.compile(
        std.testing.allocator,
        &plans.definition_plan,
        &cached_storage,
    )).?;
}

fn cachedStoragePlan(
    plans: *const TransactionTestPlans,
) !storage.Plan {
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer encoder.deinit();
    try storage.encodeCache(&plans.storage_plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached_storage = try storage.decodeCache(
        std.testing.allocator,
        &decoder,
    );
    errdefer cached_storage.deinit(std.testing.allocator);
    try decoder.finish();
    try storage.validateCachePlan(
        &cached_storage,
        &plans.definition_plan,
    );
    return cached_storage;
}

fn executeTestWithStorage(
    plans: *const TransactionTestPlans,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
    operation: []const u8,
    repo_root: []const u8,
    documents: []const validation.InputDocument,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    return transact(
        std.testing.allocator,
        &plans.definition_plan,
        &plans.closure,
        plans.entry_path,
        &plans.validation_plan,
        storage_plan,
        event_protocol,
        operation,
        repo_root,
        documents,
        parameters,
    );
}

fn appendFirstChainedEvent(
    plans: *const TransactionTestPlans,
    protocol_plan: *const protocol.Plan,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    var result = try plans.execute(
        protocol_plan,
        "append",
        &.{.{ .name = "request", .bytes = first_chained_request }},
        parameters,
    );
    errdefer result.deinit(std.testing.allocator);
    try std.testing.expect(result.storage_mutated);
    try std.testing.expectEqual(
        @as(usize, 1),
        result.generated_outputs.len,
    );
    try std.testing.expectEqualStrings(
        "capability",
        result.generated_outputs[0].name,
    );
    try std.testing.expectEqual(
        @as(usize, "TOK-".len + 64),
        result.generated_outputs[0].value.len,
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        result.generated_outputs[0].value,
        "TOK-",
    ));
    const event = result.returned_content orelse
        return error.TestExpectedEqual;
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            event,
            result.generated_outputs[0].value,
        ) == null,
    );
    return result;
}

fn firstChainedDigestAlloc(result: *const Result) ![]u8 {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        result.returned_content.?,
        .{},
    );
    defer parsed.deinit();
    const object = try definition_core.json.object(parsed.value);
    const body = try definition_core.json.object(
        try definition_core.json.field(object, "body"),
    );
    const capability_digest =
        try definition_core.canonical_json.digestBytesAlloc(
            std.testing.allocator,
            result.generated_outputs[0].value,
        );
    defer std.testing.allocator.free(capability_digest);
    try std.testing.expectEqualStrings(
        capability_digest,
        try definition_core.json.requiredString(
            body,
            "capability_digest",
        ),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try definition_core.json.integer(
            try definition_core.json.field(object, "sequence"),
        ),
    );
    try std.testing.expectEqualStrings(
        "e-1",
        try definition_core.json.requiredString(object, "event_id"),
    );
    try std.testing.expectEqualStrings(
        "example-event/v1",
        try definition_core.json.requiredString(object, "schema"),
    );
    try std.testing.expectEqualStrings(
        chained_genesis_digest,
        try definition_core.json.requiredString(object, "previous_digest"),
    );
    return std.testing.allocator.dupe(
        u8,
        try definition_core.json.requiredString(object, "event_digest"),
    );
}

fn expectSecondChainedEventAndDuplicate(
    plans: *const TransactionTestPlans,
    protocol_plan: *const protocol.Plan,
    parameters: *const definition_core.parameters.Bindings,
    first_digest: []const u8,
) !void {
    var second = try plans.execute(
        protocol_plan,
        "append",
        &.{.{ .name = "request", .bytes = second_chained_request }},
        parameters,
    );
    defer second.deinit(std.testing.allocator);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        second.returned_content.?,
        .{},
    );
    defer parsed.deinit();
    const object = try definition_core.json.object(parsed.value);
    try std.testing.expectEqual(
        @as(i64, 2),
        try definition_core.json.integer(
            try definition_core.json.field(object, "sequence"),
        ),
    );
    try std.testing.expectEqualStrings(
        first_digest,
        try definition_core.json.requiredString(object, "previous_digest"),
    );
    var duplicate = try plans.execute(
        protocol_plan,
        "append",
        &.{.{ .name = "request", .bytes = second_chained_request }},
        parameters,
    );
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expect(!duplicate.storage_mutated);
    try std.testing.expectEqual(
        @as(usize, 0),
        duplicate.generated_outputs.len,
    );
    try std.testing.expectEqualStrings(
        second.returned_content.?,
        duplicate.returned_content.?,
    );
}

fn expectChainedReplay(
    plans: *const TransactionTestPlans,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    var resolved = try storage.resolve(
        std.testing.allocator,
        &plans.storage_plan,
        parameters,
    );
    defer resolved.deinit(std.testing.allocator);
    var snapshot = try custody.readSlot(
        std.testing.allocator,
        plans.repo_root,
        plans.definition_plan.id,
        resolved.slot(0),
    );
    defer snapshot.deinit(std.testing.allocator);
    var stats = try replay.validateSlot(
        std.testing.allocator,
        plans.repo_root,
        plans.definition_plan.id,
        resolved.slot(0),
        &snapshot,
        parameters,
        3,
        true,
    );
    defer stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), stats.records_validated);
}

test "transaction materializes passive event requests before chained append" {
    var plans = try TransactionTestPlans.init(
        chained_event_definition,
        "protocol.json",
    );
    defer plans.deinit();
    var cached_protocol = try cachedProtocolPlan(&plans);
    defer cached_protocol.deinit(std.testing.allocator);
    var protocol_plan = (try protocol.compile(
        std.testing.allocator,
        &plans.definition_plan,
        &plans.storage_plan,
    )).?;
    defer protocol_plan.deinit(std.testing.allocator);
    var first_parameters = try plans.bind(
        &.{.{ .name = "request", .raw_value = "first" }},
    );
    defer first_parameters.deinit(std.testing.allocator);
    var second_parameters = try plans.bind(
        &.{.{ .name = "request", .raw_value = "second" }},
    );
    defer second_parameters.deinit(std.testing.allocator);
    var first = try appendFirstChainedEvent(
        &plans,
        &protocol_plan,
        &first_parameters,
    );
    defer first.deinit(std.testing.allocator);
    const first_digest = try firstChainedDigestAlloc(&first);
    defer std.testing.allocator.free(first_digest);
    try expectSecondChainedEventAndDuplicate(
        &plans,
        &protocol_plan,
        &second_parameters,
        first_digest,
    );
    try expectChainedReplay(&plans, &first_parameters);
}

const plain_event_materialization =
    "{\"mode\":\"plain\",\"body_input_field\":\"record\"," ++
    "\"field_order\":[\"v\",\"source\",\"event\",\"record\"]," ++
    "\"body_order\":[\"status\",\"id\"],\"fields\":[{" ++
    "\"field\":\"event\",\"literal\":\"capture\"},{" ++
    "\"field\":\"source\",\"literal\":\"example\"},{" ++
    "\"field\":\"v\",\"literal\":1}]}";
const plain_event_definition =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/plain-events\",\"owner\":\"example\",\"requires\":{" ++
    "\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"bind-existing\",\"canonical-json\",\"compare-and-append\"," ++
    "\"event-materialization\",\"exact-object\"]},\"parameters\":{}," ++
    "\"inputs\":{\"request\":{\"codec\":\"json\",\"max_bytes\":4096}}," ++
    "\"canonicalization\":{\"steps\":[{\"op\":\"canonical-json\"," ++
    "\"input\":\"request\"}]},\"shape\":{\"documents\":{\"request\":{" ++
    "\"object\":\"exact\",\"fields\":{\"record\":{\"object\":\"exact\"," ++
    "\"fields\":{\"id\":{},\"status\":{}}}}}}}," ++
    "\"constraints\":{\"laws\":[]},\"identity\":{},\"storage\":{\"kind\":\"event-log\"," ++
    "\"slots\":{\"events\":{\"path\":\"example/plain-events.jsonl\"," ++
    "\"kind\":\"event-log\",\"codec\":\"jsonl\",\"max_bytes\":65536}}}," ++
    "\"operations\":{\"append\":{\"effects\":[{" ++
    "\"op\":\"compare-and-append\",\"slot\":\"events\",\"input\":\"request\"," ++
    "\"event\":" ++ plain_event_materialization ++ "}]}," ++
    "\"bind-existing\":{\"effects\":[{\"op\":\"bind-existing\"," ++
    "\"slot\":\"events\",\"input\":\"request\",\"event\":" ++
    plain_event_materialization ++ "}]}},\"projections\":{}," ++
    "\"bounds\":{\"max_input_bytes\":4096,\"max_store_bytes\":65536," ++
    "\"max_records\":4,\"max_output_bytes\":4096,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":4}}";
const plain_event_request =
    "{\"record\":{\"id\":\"item-1\",\"status\":\"open\"}}";
const plain_event_expected =
    "{\"v\":1,\"source\":\"example\",\"event\":\"capture\"," ++
    "\"record\":{\"status\":\"open\",\"id\":\"item-1\"}}";

fn expectPlainCachedStorage(
    plans: *const TransactionTestPlans,
    cached_storage: *const storage.Plan,
) !void {
    const cached_event = cached_storage.operations[1].effects[0].event.?;
    try std.testing.expectEqual(
        storage.EventMaterializationMode.plain,
        cached_event.mode,
    );
    try std.testing.expectEqualStrings("v", cached_event.field_order[0]);
    try std.testing.expectEqualStrings("status", cached_event.body_order[0]);
    try std.testing.expect((try protocol.compile(
        std.testing.allocator,
        &plans.definition_plan,
        cached_storage,
    )) == null);
}

fn expectPlainAppendAndReplay(
    plans: *const TransactionTestPlans,
    cached_storage: *const storage.Plan,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    var appended = try executeTestWithStorage(
        plans,
        cached_storage,
        null,
        "append",
        plans.repo_root,
        &.{.{ .name = "request", .bytes = plain_event_request }},
        parameters,
    );
    defer appended.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        plain_event_expected,
        appended.returned_content.?,
    );
    var resolved = try storage.resolve(
        std.testing.allocator,
        cached_storage,
        parameters,
    );
    defer resolved.deinit(std.testing.allocator);
    var snapshot = try custody.readSlot(
        std.testing.allocator,
        plans.repo_root,
        plans.definition_plan.id,
        resolved.slot(0),
    );
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        plain_event_expected ++ "\n",
        snapshot.content,
    );
    var stats = try replay.validateSlot(
        std.testing.allocator,
        plans.repo_root,
        plans.definition_plan.id,
        resolved.slot(0),
        &snapshot,
        parameters,
        4,
        false,
    );
    defer stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), stats.records_validated);
}

fn expectPlainExistingBinding(
    plans: *const TransactionTestPlans,
    cached_storage: *const storage.Plan,
    parameters: *const definition_core.parameters.Bindings,
) !void {
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
        plain_event_expected ++ "\n",
    );
    var bound = try executeTestWithStorage(
        plans,
        cached_storage,
        null,
        "bind-existing",
        binding_root,
        &.{},
        parameters,
    );
    defer bound.deinit(std.testing.allocator);
    try std.testing.expect(bound.storage_mutated);
    try std.testing.expectEqualStrings("bound", bound.effects[0].result);
}

test "plain event materialization preserves declared bytes through replay and binding" {
    var plans = try TransactionTestPlans.init(
        plain_event_definition,
        "protocol.json",
    );
    defer plans.deinit();
    var cached_storage = try cachedStoragePlan(&plans);
    defer cached_storage.deinit(std.testing.allocator);
    try expectPlainCachedStorage(&plans, &cached_storage);
    var parameters = try plans.bind(&.{});
    defer parameters.deinit(std.testing.allocator);
    try expectPlainAppendAndReplay(&plans, &cached_storage, &parameters);
    try expectPlainExistingBinding(&plans, &cached_storage, &parameters);
}

const capability_protocol_definition =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/capability-protocol","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["body-digest","canonical-json","compare-and-append","cross-input-equal","enum","event-digest","event-envelope","event-kinds","event-materialization","exact-object","path-format","previous-digest","reducer","replay","secure-token","sequence","sha256"]},"parameters":{"capability":{"type":"string","required":false},"stream":{"type":"safe_identifier","required":true}},"inputs":{"abort":{"codec":"json","required":false,"max_bytes":4096},"consume":{"codec":"json","required":false,"max_bytes":4096},"prepare":{"codec":"json","required":false,"max_bytes":4096}},"canonicalization":{"steps":[{"op":"canonical-json","input":"abort"},{"op":"canonical-json","input":"consume"},{"op":"canonical-json","input":"prepare"}]},"shape":{"documents":{"abort":{"object":"exact","fields":{"body":{"object":"exact","fields":{"step_id":{}}},"kind":{"enum":["aborted"]},"stream_id":{}}},"consume":{"object":"exact","fields":{"body":{"object":"exact","fields":{"step_id":{}}},"kind":{"enum":["consumed"]},"stream_id":{}}},"prepare":{"object":"exact","fields":{"body":{"object":"exact","fields":{"step_id":{}}},"kind":{"enum":["prepared"]},"stream_id":{}},"event_envelope":{"keys":["body","body_digest","event_digest","kind","previous_digest","sequence","stream_id"],"sequence":"/sequence","kind":"/kind","previous_digest":"/previous_digest","body":"/body","body_digest":"/body_digest","event_digest":"/event_digest","partition_bindings":[{"parameter":"stream","event_value":"/stream_id"}]}}}},"constraints":{"laws":[["sequence",{"start":1}],["previous-digest",{"genesis":null}],["body-digest"],["event-digest"],["event-kinds",{"values":["aborted","consumed","prepared"]}],["reducer",{"mode":"retained","event_kind":"/kind","registers":[{"name":"pending","max_bytes":4096}],"admissions":[{"on":"prepared","requires":[],"forbids":["pending"],"rules":[],"actions":[{"op":"set","register":"pending","input":"event","path":"/body"}]},{"on":"consumed","requires":["pending"],"forbids":[],"rules":[["cross-input-equal",{"input":"event","left_input":"event","left":"/body/capability_digest","right_input":"pending","right":"/capability_digest"}],["cross-input-equal",{"input":"event","left_input":"event","left":"/body/step_id","right_input":"pending","right":"/step_id"}]],"actions":[{"op":"clear","register":"pending"}]},{"on":"aborted","requires":["pending"],"forbids":[],"rules":[["cross-input-equal",{"input":"event","left_input":"event","left":"/body/capability_digest","right_input":"pending","right":"/capability_digest"}],["cross-input-equal",{"input":"event","left_input":"event","left":"/body/step_id","right_input":"pending","right":"/step_id"}]],"actions":[{"op":"clear","register":"pending"}]}]}]]},"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/{stream}/capabilities.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},"operations":{"abort":{"effects":[{"op":"compare-and-append","slot":"events","input":"abort","event":{"mode":"chained","body_input_field":"body","fields":[{"field":"kind","input_field":"kind"},{"field":"stream_id","input_field":"stream_id"}],"body_fields":[{"field":"capability_digest","state_value":{"register":"pending","path":"/capability_digest"}}],"forbidden_parameters":["capability"]}}]},"consume":{"effects":[{"op":"compare-and-append","slot":"events","input":"consume","event":{"mode":"chained","body_input_field":"body","fields":[{"field":"kind","input_field":"kind"},{"field":"stream_id","input_field":"stream_id"}],"body_fields":[{"field":"capability_digest","parameter_sha256":{"parameter":"capability","expected_state":{"register":"pending","path":"/capability_digest"}}}]}}]},"prepare":{"effects":[{"op":"compare-and-append","slot":"events","input":"prepare","event":{"mode":"chained","body_input_field":"body","fields":[{"field":"kind","input_field":"kind"},{"field":"stream_id","input_field":"stream_id"}],"generate":[{"name":"capability","op":"secure-token","prefix":"AKC2-","bytes":32}],"body_fields":[{"field":"capability_digest","generated_sha256":"capability"}],"forbidden_parameters":["capability"]}}]}},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":8,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}}
;

const capability_prepare_input =
    "{\"body\":{\"step_id\":\"step-1\"},\"kind\":\"prepared\"," ++
    "\"stream_id\":\"stream-1\"}";
const capability_consume_input =
    "{\"body\":{\"step_id\":\"step-1\"},\"kind\":\"consumed\"," ++
    "\"stream_id\":\"stream-1\"}";
const capability_second_prepare_input =
    "{\"body\":{\"step_id\":\"step-2\"},\"kind\":\"prepared\"," ++
    "\"stream_id\":\"stream-1\"}";
const capability_abort_input =
    "{\"body\":{\"step_id\":\"step-2\"},\"kind\":\"aborted\"," ++
    "\"stream_id\":\"stream-1\"}";

fn prepareCapability(
    plans: *const TransactionTestPlans,
    protocol_plan: *const protocol.Plan,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    var result = try plans.execute(
        protocol_plan,
        "prepare",
        &.{.{ .name = "prepare", .bytes = capability_prepare_input }},
        parameters,
    );
    errdefer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        @as(usize, 1),
        result.generated_outputs.len,
    );
    return result;
}

fn expectCapabilityConsume(
    plans: *const TransactionTestPlans,
    protocol_plan: *const protocol.Plan,
    raw_capability: []const u8,
) !void {
    var wrong = try plans.bind(&.{
        .{ .name = "capability", .raw_value = "AKC2-wrong" },
        .{ .name = "stream", .raw_value = "stream-1" },
    });
    defer wrong.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.EventCapabilityMismatch,
        plans.execute(
            protocol_plan,
            "consume",
            &.{.{ .name = "consume", .bytes = capability_consume_input }},
            &wrong,
        ),
    );
    var correct = try plans.bind(&.{
        .{ .name = "capability", .raw_value = raw_capability },
        .{ .name = "stream", .raw_value = "stream-1" },
    });
    defer correct.deinit(std.testing.allocator);
    var consumed = try plans.execute(
        protocol_plan,
        "consume",
        &.{.{ .name = "consume", .bytes = capability_consume_input }},
        &correct,
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
}

fn expectCapabilityAbort(
    plans: *const TransactionTestPlans,
    protocol_plan: *const protocol.Plan,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    var prepared = try plans.execute(
        protocol_plan,
        "prepare",
        &.{.{
            .name = "prepare",
            .bytes = capability_second_prepare_input,
        }},
        parameters,
    );
    defer prepared.deinit(std.testing.allocator);
    const digest = try definition_core.canonical_json.digestBytesAlloc(
        std.testing.allocator,
        prepared.generated_outputs[0].value,
    );
    defer std.testing.allocator.free(digest);
    var aborted = try plans.execute(
        protocol_plan,
        "abort",
        &.{.{ .name = "abort", .bytes = capability_abort_input }},
        parameters,
    );
    defer aborted.deinit(std.testing.allocator);
    try std.testing.expect(
        std.mem.indexOf(u8, aborted.returned_content.?, digest) != null,
    );
}

fn expectCapabilityForbidden(
    plans: *const TransactionTestPlans,
    protocol_plan: *const protocol.Plan,
    raw_capability: []const u8,
) !void {
    var forbidden = try plans.bind(&.{
        .{ .name = "capability", .raw_value = raw_capability },
        .{ .name = "stream", .raw_value = "stream-1" },
    });
    defer forbidden.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ForbiddenEventParameter,
        plans.execute(
            protocol_plan,
            "prepare",
            &.{.{ .name = "prepare", .bytes = capability_prepare_input }},
            &forbidden,
        ),
    );
}

test "transaction keeps generated capabilities transient and checks retained custody" {
    var plans = try TransactionTestPlans.init(
        capability_protocol_definition,
        "protocol.json",
    );
    defer plans.deinit();
    var cached_protocol = try cachedProtocolPlan(&plans);
    defer cached_protocol.deinit(std.testing.allocator);
    var protocol_plan = (try protocol.compile(
        std.testing.allocator,
        &plans.definition_plan,
        &plans.storage_plan,
    )).?;
    defer protocol_plan.deinit(std.testing.allocator);
    var base_parameters = try plans.bind(
        &.{.{ .name = "stream", .raw_value = "stream-1" }},
    );
    defer base_parameters.deinit(std.testing.allocator);
    var prepared = try prepareCapability(
        &plans,
        &protocol_plan,
        &base_parameters,
    );
    defer prepared.deinit(std.testing.allocator);
    const raw_capability = prepared.generated_outputs[0].value;
    try expectCapabilityConsume(&plans, &protocol_plan, raw_capability);
    try expectCapabilityAbort(&plans, &protocol_plan, &base_parameters);
    try expectCapabilityForbidden(&plans, &protocol_plan, raw_capability);
}

const definition_bound_event_definition =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/chained-events\",\"owner\":\"example\",\"requires\":{" ++
    "\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"body-digest\",\"compare-and-append\",\"event-digest\"," ++
    "\"event-envelope\",\"event-kinds\",\"exact-object\"," ++
    "\"previous-digest\",\"replay\",\"sequence\"]},\"parameters\":{}," ++
    "\"inputs\":{\"event\":{\"codec\":\"json\",\"max_bytes\":4096}}," ++
    "\"canonicalization\":{},\"shape\":{\"documents\":{\"event\":{" ++
    "\"object\":\"exact\",\"fields\":{\"body\":{},\"body_digest\":{}," ++
    "\"event_digest\":{},\"kind\":{},\"previous_digest\":{},\"sequence\":{}}," ++
    "\"event_envelope\":{\"keys\":[\"body\",\"body_digest\"," ++
    "\"event_digest\",\"kind\",\"previous_digest\",\"sequence\"]," ++
    "\"sequence\":\"/sequence\",\"kind\":\"/kind\"," ++
    "\"previous_digest\":\"/previous_digest\",\"body\":\"/body\"," ++
    "\"body_digest\":\"/body_digest\",\"event_digest\":\"/event_digest\"}}}}," ++
    "\"constraints\":{\"event_log\":{\"start\":1,\"genesis\":null," ++
    "\"kinds\":[\"created\",\"updated\"]}}," ++
    "\"identity\":{},\"storage\":{\"kind\":\"event-log\",\"slots\":{" ++
    "\"events\":{\"path\":\"example/chained-events.jsonl\"," ++
    "\"kind\":\"event-log\",\"codec\":\"jsonl\",\"max_bytes\":65536}}}," ++
    "\"operations\":{\"append\":{\"effects\":[{" ++
    "\"op\":\"compare-and-append\",\"slot\":\"events\",\"input\":\"event\"}]}}," ++
    "\"projections\":{},\"bounds\":{\"max_input_bytes\":4096," ++
    "\"max_store_bytes\":65536,\"max_records\":3,\"max_output_bytes\":4096," ++
    "\"max_diagnostics\":8,\"max_reducer_states\":4}}";

fn appendDefinitionBoundPair(
    plans: *const TransactionTestPlans,
    protocol_plan: *const protocol.Plan,
    parameters: *const definition_core.parameters.Bindings,
) !ChainedEvent {
    var first_event = try chainedEventAlloc(
        std.testing.allocator,
        1,
        "created",
        null,
        "{\"id\":\"item-1\",\"status\":\"open\"}",
    );
    defer first_event.deinit(std.testing.allocator);
    var first = try plans.execute(
        protocol_plan,
        "append",
        &.{.{ .name = "event", .bytes = first_event.bytes }},
        parameters,
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
    errdefer second_event.deinit(std.testing.allocator);
    var second = try plans.execute(
        protocol_plan,
        "append",
        &.{.{ .name = "event", .bytes = second_event.bytes }},
        parameters,
    );
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second.storage_mutated);
    return second_event;
}

fn expectBrokenDefinitionBoundEvent(
    plans: *const TransactionTestPlans,
    protocol_plan: *const protocol.Plan,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    var event = try chainedEventAlloc(
        std.testing.allocator,
        3,
        "updated",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "{\"id\":\"item-1\",\"status\":\"archived\"}",
    );
    defer event.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.EventPreviousDigestMismatch,
        plans.execute(
            protocol_plan,
            "append",
            &.{.{ .name = "event", .bytes = event.bytes }},
            parameters,
        ),
    );
}

fn expectDefinitionBoundReplay(
    plans: *const TransactionTestPlans,
    protocol_plan: *const protocol.Plan,
    parameters: *const definition_core.parameters.Bindings,
    expected_digest: []const u8,
) !void {
    var resolved = try storage.resolve(
        std.testing.allocator,
        &plans.storage_plan,
        parameters,
    );
    defer resolved.deinit(std.testing.allocator);
    const slot = resolved.slot(protocol_plan.target_slot_index);
    var snapshot = try custody.readSlot(
        std.testing.allocator,
        plans.repo_root,
        plans.definition_plan.id,
        slot,
    );
    defer snapshot.deinit(std.testing.allocator);
    var stats = try replay.validateSlot(
        std.testing.allocator,
        plans.repo_root,
        plans.definition_plan.id,
        slot,
        &snapshot,
        parameters,
        plans.definition_plan.bounds.max_records,
        true,
    );
    defer stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), stats.records_validated);
    try std.testing.expectEqual(@as(usize, 2), stats.protocol_state.?.records);
    try std.testing.expectEqualStrings(
        expected_digest,
        stats.protocol_state.?.previousDigest().?,
    );
    try std.testing.expectError(
        error.HistoricalProtocolBindingMismatch,
        replay.validateSlot(
            std.testing.allocator,
            plans.repo_root,
            plans.definition_plan.id,
            slot,
            &snapshot,
            parameters,
            plans.definition_plan.bounds.max_records,
            false,
        ),
    );
}

test "transaction admits and replays a definition-bound event chain" {
    var plans = try TransactionTestPlans.init(
        definition_bound_event_definition,
        "protocol.json",
    );
    defer plans.deinit();
    var protocol_plan = (try protocol.compile(
        std.testing.allocator,
        &plans.definition_plan,
        &plans.storage_plan,
    )).?;
    defer protocol_plan.deinit(std.testing.allocator);
    var parameters = try plans.bind(&.{});
    defer parameters.deinit(std.testing.allocator);
    var second_event = try appendDefinitionBoundPair(
        &plans,
        &protocol_plan,
        &parameters,
    );
    defer second_event.deinit(std.testing.allocator);
    try expectBrokenDefinitionBoundEvent(
        &plans,
        &protocol_plan,
        &parameters,
    );
    try expectDefinitionBoundReplay(
        &plans,
        &protocol_plan,
        &parameters,
        second_event.digest,
    );
}

const document_history_definition =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/document-history\",\"owner\":\"example\",\"requires\":{" ++
    "\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"compare-and-replace\",\"create-new\",\"exact-object\"," ++
    "\"idempotency-key\"]},\"parameters\":{\"request\":{" ++
    "\"type\":\"safe_identifier\",\"required\":false},\"revision\":{" ++
    "\"type\":\"digest\",\"required\":false}},\"inputs\":{\"record\":{" ++
    "\"codec\":\"json\",\"max_bytes\":4096}},\"canonicalization\":{}," ++
    "\"shape\":{\"documents\":{\"record\":{\"object\":\"exact\",\"fields\":{" ++
    "\"value\":{}}}}},\"constraints\":{\"laws\":[]},\"identity\":{}," ++
    "\"storage\":{\"kind\":\"addressed-document\",\"slots\":{\"current\":{" ++
    "\"path\":\"example/current.json\",\"kind\":\"document\"," ++
    "\"codec\":\"json\",\"max_bytes\":4096}}},\"operations\":{\"create\":{" ++
    "\"effects\":[{\"op\":\"create-new\",\"slot\":\"current\"," ++
    "\"input\":\"record\"}]},\"replace\":{\"effects\":[{" ++
    "\"op\":\"compare-and-replace\",\"slot\":\"current\",\"input\":\"record\"," ++
    "\"expected_revision_param\":\"revision\"," ++
    "\"idempotency_param\":\"request\"}]}},\"projections\":{}," ++
    "\"bounds\":{\"max_input_bytes\":4096,\"max_store_bytes\":4096," ++
    "\"max_records\":10,\"max_output_bytes\":4096,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":4}}";

const parameter_bound_document_definition =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/parameter-bound-document\",\"owner\":\"example\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"create-new\",\"exact-object\",\"path-format\"]}," ++
    "\"parameters\":{\"id\":{\"type\":\"safe_identifier\"," ++
    "\"required\":true}},\"inputs\":{\"record\":{\"codec\":\"json\"," ++
    "\"max_bytes\":4096}},\"canonicalization\":{}," ++
    "\"shape\":{\"documents\":{\"record\":{\"object\":\"exact\"," ++
    "\"fields\":{\"id\":{},\"value\":{}}}}},\"constraints\":{\"laws\":[]}," ++
    "\"identity\":{},\"storage\":{\"kind\":\"addressed-document\"," ++
    "\"slots\":{\"current\":{\"path\":\"example/{id}/record.json\"," ++
    "\"kind\":\"document\",\"codec\":\"json\",\"max_bytes\":4096}}}," ++
    "\"operations\":{\"create\":{\"effects\":[{\"op\":\"create-new\"," ++
    "\"slot\":\"current\",\"input\":\"record\",\"parameter_bindings\":[" ++
    "{\"parameter\":\"id\",\"path\":\"/id\"}]}]}},\"projections\":{}," ++
    "\"bounds\":{\"max_input_bytes\":4096,\"max_store_bytes\":4096," ++
    "\"max_records\":10,\"max_output_bytes\":4096,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":4}}";

test "transaction binds logical path parameters to validated input fields" {
    var plans = try TransactionTestPlans.init(
        parameter_bound_document_definition,
        "document.json",
    );
    defer plans.deinit();
    var wrong = try plans.bind(&.{
        .{ .name = "id", .raw_value = "wrong" },
    });
    defer wrong.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.EffectParameterBindingMismatch,
        plans.execute(
            null,
            "create",
            &.{.{ .name = "record", .bytes = "{\"id\":\"expected\",\"value\":1}" }},
            &wrong,
        ),
    );
    var expected = try plans.bind(&.{
        .{ .name = "id", .raw_value = "expected" },
    });
    defer expected.deinit(std.testing.allocator);
    var created = try plans.execute(
        null,
        "create",
        &.{.{ .name = "record", .bytes = "{\"id\":\"expected\",\"value\":1}" }},
        &expected,
    );
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "example/expected/record.json",
        created.effects[0].logical_ref,
    );
}

fn createAndReplaceDocument(
    plans: *const TransactionTestPlans,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    var created = try plans.execute(
        null,
        "create",
        &.{.{ .name = "record", .bytes = "{\"value\": 1}" }},
        parameters,
    );
    defer created.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.MissingOperationParameter,
        plans.execute(
            null,
            "replace",
            &.{.{ .name = "record", .bytes = "{\"value\": 2}" }},
            parameters,
        ),
    );
    var replace_parameters = try plans.bind(&.{
        .{ .name = "request", .raw_value = "replace-once" },
        .{
            .name = "revision",
            .raw_value = created.effects[0].revision_after,
        },
    });
    defer replace_parameters.deinit(std.testing.allocator);
    var replaced = try plans.execute(
        null,
        "replace",
        &.{.{ .name = "record", .bytes = "{\"value\": 2}" }},
        &replace_parameters,
    );
    errdefer replaced.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "created",
        created.effects[0].result,
    );
    try std.testing.expectEqualStrings(
        "replaced",
        replaced.effects[0].result,
    );
    return replaced;
}

fn duplicateDocumentReplacement(
    plans: *const TransactionTestPlans,
    replaced: *const Result,
) !definition_core.parameters.Bindings {
    var parameters = try plans.bind(&.{
        .{ .name = "request", .raw_value = "replace-once" },
        .{
            .name = "revision",
            .raw_value = replaced.effects[0].revision_after,
        },
    });
    errdefer parameters.deinit(std.testing.allocator);
    var duplicate = try plans.execute(
        null,
        "replace",
        &.{.{ .name = "record", .bytes = "{\"value\": 2}" }},
        &parameters,
    );
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expect(!duplicate.storage_mutated);
    try std.testing.expectEqualStrings(
        "idempotent",
        duplicate.effects[0].result,
    );
    return parameters;
}

fn expectDocumentReplayAndCorruption(
    plans: *const TransactionTestPlans,
    parameters: *const definition_core.parameters.Bindings,
    duplicate_parameters: *const definition_core.parameters.Bindings,
) !void {
    var resolved = try storage.resolve(
        std.testing.allocator,
        &plans.storage_plan,
        parameters,
    );
    defer resolved.deinit(std.testing.allocator);
    var snapshot = try custody.readSlot(
        std.testing.allocator,
        plans.repo_root,
        plans.definition_plan.id,
        resolved.slot(0),
    );
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.binding.rows.len);
    var stats = try replay.validateSlot(
        std.testing.allocator,
        plans.repo_root,
        plans.definition_plan.id,
        resolved.slot(0),
        &snapshot,
        parameters,
        plans.definition_plan.bounds.max_records,
        false,
    );
    defer stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), stats.records_validated);
    try std.testing.expectEqual(@as(usize, 1), stats.definition_versions);
    try std.testing.expectEqualStrings("{\"value\":2}", snapshot.content);
    try corruptDocumentRevision(plans, &snapshot);
    try std.testing.expectError(
        error.RevisionArchiveDigestMismatch,
        plans.execute(
            null,
            "replace",
            &.{.{ .name = "record", .bytes = "{\"value\": 2}" }},
            duplicate_parameters,
        ),
    );
    try std.testing.expectError(
        error.RevisionArchiveDigestMismatch,
        replay.validateSlot(
            std.testing.allocator,
            plans.repo_root,
            plans.definition_plan.id,
            resolved.slot(0),
            &snapshot,
            parameters,
            plans.definition_plan.bounds.max_records,
            false,
        ),
    );
}

fn corruptDocumentRevision(
    plans: *const TransactionTestPlans,
    snapshot: *const custody.SlotSnapshot,
) !void {
    const path = try revision_archive.pathAlloc(
        std.testing.allocator,
        plans.repo_root,
        snapshot.binding.rows[1].revision_before.?,
    );
    defer std.testing.allocator.free(path);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        path,
        "{\"value\":9}",
    );
}

test "document replacements replay from immutable prior revisions" {
    var plans = try TransactionTestPlans.init(
        document_history_definition,
        "document.json",
    );
    defer plans.deinit();
    var parameters = try plans.bind(
        &.{.{ .name = "request", .raw_value = "replace-once" }},
    );
    defer parameters.deinit(std.testing.allocator);
    var replaced = try createAndReplaceDocument(
        &plans,
        &parameters,
    );
    defer replaced.deinit(std.testing.allocator);
    var duplicate_parameters = try duplicateDocumentReplacement(
        &plans,
        &replaced,
    );
    defer duplicate_parameters.deinit(std.testing.allocator);
    try expectDocumentReplayAndCorruption(
        &plans,
        &parameters,
        &duplicate_parameters,
    );
}

const unbound_store_definition =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/unbound\",\"owner\":\"example\",\"requires\":{" ++
    "\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"compare-and-append\"]},\"parameters\":{},\"inputs\":{\"event\":{" ++
    "\"codec\":\"json\",\"max_bytes\":1024}},\"canonicalization\":{}," ++
    "\"shape\":{},\"constraints\":{\"laws\":[]},\"identity\":{}," ++
    "\"storage\":{\"kind\":\"event-log\",\"slots\":{\"events\":{" ++
    "\"path\":\"example/events.jsonl\",\"codec\":\"jsonl\"," ++
    "\"max_bytes\":4096}}},\"operations\":{\"append\":{\"effects\":[{" ++
    "\"op\":\"compare-and-append\",\"slot\":\"events\",\"input\":\"event\"}]}}," ++
    "\"projections\":{},\"bounds\":{\"max_input_bytes\":1024," ++
    "\"max_store_bytes\":4096,\"max_records\":10,\"max_output_bytes\":1024," ++
    "\"max_diagnostics\":8,\"max_reducer_states\":4}}";

test "transaction fails closed for an unbound existing store" {
    var plans = try TransactionTestPlans.init(
        unbound_store_definition,
        "protocol.json",
    );
    defer plans.deinit();
    var parameters = try plans.bind(&.{});
    defer parameters.deinit(std.testing.allocator);
    const event_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ plans.repo_root, ".ledger", "example", "events.jsonl" },
    );
    defer std.testing.allocator.free(event_path);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        event_path,
        "{\"legacy\":true}\n",
    );
    try std.testing.expectError(
        error.UnboundStore,
        plans.execute(
            null,
            "append",
            &.{.{ .name = "event", .bytes = "{\"kind\":\"new\"}" }},
            &parameters,
        ),
    );
}

const content_idempotency_definition =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/content-idempotency","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["bind-existing","canonical-json","compare-and-append","event-materialization","exact-object","idempotency-key","sha1"]},"parameters":{"allow_duplicate":{"type":"boolean","required":false,"default":false}},"inputs":{"submission":{"codec":"json","max_bytes":4096}},"canonicalization":{"steps":[{"op":"canonical-json","input":"submission"}]},"shape":{"documents":{"submission":{"object":"exact","fields":{"record":{"object":"exact","fields":{"context":{"object":"exact","fields":{"branch":{},"paths":{},"repo":{}}},"status":{},"summary":{}}}}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/content-idempotency.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},"operations":{"bind":{"effects":[{"op":"bind-existing","slot":"events","input":"submission","event_from_operation":"capture"}]},"capture":{"effects":[{"op":"compare-and-append","slot":"events","input":"submission","event":{"mode":"plain","body_input_field":"record","field_order":["event","record"],"body_order":["status","summary","context","fingerprint"],"object_orders":[{"path":"/context","fields":["repo","branch","paths"]}],"escape_non_ascii":true,"fields":[{"field":"event","literal":"capture"}],"derive":[{"name":"fingerprint","op":"sha1","encoding":"hex","prefix_bytes":16,"fragments":[{"input_text":"/record/status"},{"literal":"|"},{"input_text":"/record/summary","transform":"ascii-lower"}],"max_bytes":4096}],"idempotency":{"derived":"fingerprint","bypass_param":"allow_duplicate"},"body_fields":[{"field":"fingerprint","derived":"fingerprint"}]}}]}},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
;

const content_idempotency_request =
    "{\"record\":{\"status\":\"do_more\",\"summary\":\"MiXeD CaSe\"," ++
    "\"context\":{\"branch\":\"main\",\"paths\":[],\"repo\":\"café\"}}}";
const content_idempotency_event =
    "{\"event\":\"capture\",\"record\":{\"status\":\"do_more\"," ++
    "\"summary\":\"MiXeD CaSe\",\"context\":{\"repo\":\"caf\\u00E9\"," ++
    "\"branch\":\"main\",\"paths\":[]}," ++
    "\"fingerprint\":\"eea046b1709337f1\"}}";

fn expectContentIdempotencyCache(
    plans: *const TransactionTestPlans,
    storage_plan: *const storage.Plan,
) !void {
    const operation = storage_plan.findOperation("bind") orelse
        return error.TestExpectedBindOperation;
    try std.testing.expect(
        operation.effects[0].event.?.idempotency != null,
    );
    try storage.validateCachePlan(
        storage_plan,
        &plans.definition_plan,
    );
}

fn captureInitialContentEvent(
    plans: *const TransactionTestPlans,
    storage_plan: *const storage.Plan,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    var first = try executeTestWithStorage(
        plans,
        storage_plan,
        null,
        "capture",
        plans.repo_root,
        &.{.{
            .name = "submission",
            .bytes = content_idempotency_request,
        }},
        parameters,
    );
    errdefer first.deinit(std.testing.allocator);
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
        content_idempotency_event,
        first.returned_content.?,
    );
    var duplicate = try executeTestWithStorage(
        plans,
        storage_plan,
        null,
        "capture",
        plans.repo_root,
        &.{.{
            .name = "submission",
            .bytes = content_idempotency_request,
        }},
        parameters,
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
    return first;
}

fn expectLegacyContentBinding(
    plans: *const TransactionTestPlans,
    storage_plan: *const storage.Plan,
    parameters: *const definition_core.parameters.Bindings,
    expected: []const u8,
) !void {
    var legacy_tmp = std.testing.tmpDir(.{});
    defer legacy_tmp.cleanup();
    const legacy_root = try legacy_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(legacy_root);
    const event_path = try std.fs.path.join(
        std.testing.allocator,
        &.{
            legacy_root,
            ".ledger",
            "example",
            "content-idempotency.jsonl",
        },
    );
    defer std.testing.allocator.free(event_path);
    const content = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}\n",
        .{expected},
    );
    defer std.testing.allocator.free(content);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        event_path,
        content,
    );
    var binding = try executeTestWithStorage(
        plans,
        storage_plan,
        null,
        "bind",
        legacy_root,
        &.{},
        parameters,
    );
    defer binding.deinit(std.testing.allocator);
    try std.testing.expect(binding.storage_mutated);
    try std.testing.expectEqualStrings("bound", binding.effects[0].result);
    var duplicate = try executeTestWithStorage(
        plans,
        storage_plan,
        null,
        "capture",
        legacy_root,
        &.{.{
            .name = "submission",
            .bytes = content_idempotency_request,
        }},
        parameters,
    );
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expect(!duplicate.storage_mutated);
    try std.testing.expectEqualStrings(
        expected,
        duplicate.returned_content.?,
    );
}

fn expectContentIdempotencyBypass(
    plans: *const TransactionTestPlans,
    storage_plan: *const storage.Plan,
    ordinary: *const definition_core.parameters.Bindings,
    bypass: *const definition_core.parameters.Bindings,
    expected: []const u8,
) !void {
    var allowed = try executeTestWithStorage(
        plans,
        storage_plan,
        null,
        "capture",
        plans.repo_root,
        &.{.{
            .name = "submission",
            .bytes = content_idempotency_request,
        }},
        bypass,
    );
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.storage_mutated);
    var duplicate = try executeTestWithStorage(
        plans,
        storage_plan,
        null,
        "capture",
        plans.repo_root,
        &.{.{
            .name = "submission",
            .bytes = content_idempotency_request,
        }},
        ordinary,
    );
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expect(!duplicate.storage_mutated);
    try std.testing.expectEqualStrings(expected, duplicate.returned_content.?);
    try expectContentEventCount(plans, 2);
}

fn expectContentEventCount(
    plans: *const TransactionTestPlans,
    expected: usize,
) !void {
    const event_path = try std.fs.path.join(
        std.testing.allocator,
        &.{
            plans.repo_root,
            ".ledger",
            "example",
            "content-idempotency.jsonl",
        },
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
    try std.testing.expectEqual(expected, count);
}

test "plain event idempotency derives a transformed truncated digest with an explicit bypass" {
    var plans = try TransactionTestPlans.init(
        content_idempotency_definition,
        "protocol.json",
    );
    defer plans.deinit();
    var storage_plan = try cachedStoragePlan(&plans);
    defer storage_plan.deinit(std.testing.allocator);
    try expectContentIdempotencyCache(&plans, &storage_plan);
    var ordinary = try plans.bind(&.{});
    defer ordinary.deinit(std.testing.allocator);
    var bypass = try plans.bind(
        &.{.{ .name = "allow_duplicate", .raw_value = "true" }},
    );
    defer bypass.deinit(std.testing.allocator);
    var first = try captureInitialContentEvent(
        &plans,
        &storage_plan,
        &ordinary,
    );
    defer first.deinit(std.testing.allocator);
    try expectLegacyContentBinding(
        &plans,
        &storage_plan,
        &ordinary,
        first.returned_content.?,
    );
    try expectContentIdempotencyBypass(
        &plans,
        &storage_plan,
        &ordinary,
        &bypass,
        first.returned_content.?,
    );
}
