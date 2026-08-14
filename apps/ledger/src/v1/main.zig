const std = @import("std");
const builtin = @import("builtin");
const app_meta = @import("app_meta");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const ledger = @import("ledger_v1_core");

const Version = std.mem.trim(u8, app_meta.version, " \t\r\n");
const max_projection_table_columns: usize = 1024;
const max_projection_table_cells: usize = 4_000_000;
threadlocal var runtime_io: ?std.Io = null;

pub const panic = if (builtin.is_test)
    std.debug.FullPanic(std.debug.defaultPanic)
else
    std.debug.simple_panic;

pub const std_options: std.Options = .{
    .signal_stack_size = switch (builtin.mode) {
        .ReleaseFast, .ReleaseSmall => null,
        .Debug, .ReleaseSafe => 1 << 18,
    },
};

const Help =
    \\ledger
    \\
    \\Passive definitions for validation, materialization, transactions, replay, and projections.
    \\
    \\usage: ledger <command> [options]
    \\
    \\definition commands:
    \\  ledger definition check --definition <file> [--format json|text]
    \\  ledger definition describe --definition <file> [--format json|text]
    \\
    \\artifact commands:
    \\  ledger validate --definition <file> --input <name>=<file|->
    \\    [--input <name>=<file>]... [--param <name>=<value>]...
    \\    [--format json|text]
    \\  ledger materialize --definition <file> --input <name>=<file|->
    \\    [--param <name>=<value>]... [--format json|text]
    \\  ledger transact --definition <file> --operation <name> --repo <path>
    \\    [--input <name>=<file|->]... [--param <name>=<value>]...
    \\    [--format json|text]
    \\  ledger project --definition <file> --projection <name> --repo <path>
    \\    [--param <name>=<value>]... [--payload-only]
    \\    [--format json|jsonl|table|text|markdown]
    \\  ledger doctor --definition <file> --repo <path>
    \\    [--param <name>=<value>]... [--format json|text]
    \\  ledger migrate-segmented --definition <file> --repo <path>
    \\    [--param <name>=<value>]... [--format json|text]
    \\
    \\recovery commands:
    \\  ledger recovery inspect --repo <path> --transaction <id>
    \\    [--format json|text]
    \\  ledger recovery reclaim --repo <path> --transaction <id>
    \\    --resource <path> --lock-id <id> --fencing-token <u64>
    \\    [--confirm-no-legacy-writers] [--format json|text]
    \\
    \\metadata commands:
    \\  ledger capabilities [--format json|text]
    \\  ledger version
    \\
    \\Definitions are passive JSON. Ledger grants no semantic authority and does not read sessions.
    \\
;

const Format = enum {
    json,
    text,

    fn parse(raw: []const u8) !Format {
        if (std.mem.eql(u8, raw, "json")) return .json;
        if (std.mem.eql(u8, raw, "text")) return .text;
        return error.UnsupportedFormat;
    }
};

const ProjectionFormat = enum {
    json,
    jsonl,
    table,
    text,
    markdown,

    fn parse(raw: []const u8) !ProjectionFormat {
        if (std.mem.eql(u8, raw, "json")) return .json;
        if (std.mem.eql(u8, raw, "jsonl")) return .jsonl;
        if (std.mem.eql(u8, raw, "table")) return .table;
        if (std.mem.eql(u8, raw, "text")) return .text;
        if (std.mem.eql(u8, raw, "markdown")) return .markdown;
        return error.UnsupportedFormat;
    }
};

const CommonArgs = struct {
    definition_path: []const u8,
    format: Format,
    input_specs: []const []const u8,
    parameter_specs: []const []const u8,

    fn deinit(self: *CommonArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.input_specs);
        allocator.free(self.parameter_specs);
        self.* = undefined;
    }
};

const TransactionArgs = struct {
    common: CommonArgs,
    operation: []const u8,
    repo_path: []const u8,

    fn deinit(self: *TransactionArgs, allocator: std.mem.Allocator) void {
        self.common.deinit(allocator);
        self.* = undefined;
    }
};

const ProjectionArgs = struct {
    definition_path: []const u8,
    projection: []const u8,
    repo_path: []const u8,
    format: ProjectionFormat,
    parameter_specs: []const []const u8,
    payload_only: bool,

    fn deinit(self: *ProjectionArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.parameter_specs);
        self.* = undefined;
    }
};

const DoctorArgs = struct {
    definition_path: []const u8,
    repo_path: []const u8,
    format: Format,
    parameter_specs: []const []const u8,

    fn deinit(self: *DoctorArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.parameter_specs);
        self.* = undefined;
    }
};

const RecoveryArgs = struct {
    repo_path: []const u8,
    transaction_id: []const u8,
    resource: ?[]const u8,
    lock_id: ?[]const u8,
    fencing_token: ?u64,
    confirm_no_legacy_writers: bool,
    format: Format,
};

const RecoveryPaths = struct {
    transaction_dir: []u8,
    counter_path: []u8,

    fn init(
        allocator: std.mem.Allocator,
        repo_path: []const u8,
        transaction_id: []const u8,
    ) !RecoveryPaths {
        try durable_store.rejectSymlinkComponents(repo_path);
        const repo_root = try std.Io.Dir.cwd().realPathFileAlloc(
            defaultIo(),
            repo_path,
            allocator,
        );
        defer allocator.free(repo_root);
        const ledger_root = try std.fs.path.join(
            allocator,
            &.{ repo_root, ".ledger" },
        );
        defer allocator.free(ledger_root);
        const transaction_dir = try std.fs.path.join(
            allocator,
            &.{ ledger_root, ".transactions", transaction_id },
        );
        errdefer allocator.free(transaction_dir);
        const counter_path = try std.fs.path.join(
            allocator,
            &.{ ledger_root, ".fencing.counter" },
        );
        errdefer allocator.free(counter_path);
        try durable_store.rejectSymlinkComponents(transaction_dir);
        try durable_store.rejectSymlinkComponents(counter_path);
        return .{
            .transaction_dir = transaction_dir,
            .counter_path = counter_path,
        };
    }

    fn deinit(self: *RecoveryPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.transaction_dir);
        allocator.free(self.counter_path);
        self.* = undefined;
    }
};

const DefinitionContext = ledger.compiled_plan.PlanSet;

const OwnedDocument = struct {
    name: []u8,
    bytes: []u8,

    fn deinit(self: *OwnedDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    runtime_io = init.io;
    defer runtime_io = null;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (requiresDurableIo(argv)) {
        ledger.transaction.installRuntimeIo(init.io);
    }
    const code = runWithArgv(init.gpa, init.environ_map, argv) catch |err| blk: {
        emitCommandError(err) catch |write_err| {
            if (isClosedPipe(write_err)) return;
            return write_err;
        };
        break :blk @as(u8, 2);
    };
    if (code != 0) std.process.exit(code);
}

fn requiresDurableIo(argv: []const []const u8) bool {
    if (argv.len < 2) return false;
    return std.mem.eql(u8, argv[1], "transact") or
        std.mem.eql(u8, argv[1], "project") or
        std.mem.eql(u8, argv[1], "doctor") or
        std.mem.eql(u8, argv[1], "migrate-segmented") or
        std.mem.eql(u8, argv[1], "recovery");
}

pub fn runWithArgv(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    if (argv.len < 2) {
        try writeStdout(Help);
        return 0;
    }
    if (isHelp(argv[1])) {
        if (argv.len != 2) return error.UnexpectedArgument;
        try writeStdout(Help);
        return 0;
    }
    if (std.mem.eql(u8, argv[1], "version") or isVersion(argv[1])) {
        if (argv.len != 2) return error.UnexpectedArgument;
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        try stdout_writer.interface.print("{s}\n", .{Version});
        return 0;
    }
    return runSubcommand(allocator, environment, argv[1], argv[2..]);
}

fn runSubcommand(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    command: []const u8,
    argv: []const []const u8,
) !u8 {
    if (std.mem.eql(u8, command, "capabilities")) {
        if (isOnlyHelp(argv)) {
            try writeStdout(Help);
            return 0;
        }
        return emitCapabilities(argv);
    }
    if (std.mem.eql(u8, command, "definition")) {
        return runDefinitionCommand(allocator, environment, argv);
    }
    if (std.mem.eql(u8, command, "recovery")) {
        return runRecoveryCommand(allocator, argv);
    }
    return runOperationCommand(allocator, environment, command, argv);
}

fn runDefinitionCommand(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    if (argv.len == 0) return error.MissingDefinitionAction;
    if (std.mem.eql(u8, argv[0], "check")) {
        if (isOnlyHelp(argv[1..])) {
            try writeStdout(Help);
            return 0;
        }
        return runDefinitionCheck(allocator, environment, argv[1..]);
    }
    if (std.mem.eql(u8, argv[0], "describe")) {
        if (isOnlyHelp(argv[1..])) {
            try writeStdout(Help);
            return 0;
        }
        return runDefinitionDescribe(allocator, environment, argv[1..]);
    }
    return error.UnknownDefinitionAction;
}

fn runOperationCommand(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    command: []const u8,
    argv: []const []const u8,
) !u8 {
    if (!isOperationCommand(command)) return error.UnknownCommand;
    if (isOnlyHelp(argv)) {
        try writeStdout(Help);
        return 0;
    }
    if (std.mem.eql(u8, command, "validate")) {
        return runValidate(allocator, environment, argv);
    }
    if (std.mem.eql(u8, command, "materialize")) {
        return runMaterialize(allocator, environment, argv);
    }
    if (std.mem.eql(u8, command, "transact")) {
        return runTransact(allocator, environment, argv);
    }
    if (std.mem.eql(u8, command, "project")) {
        return runProject(allocator, environment, argv);
    }
    if (std.mem.eql(u8, command, "doctor")) {
        return runDoctor(allocator, environment, argv);
    }
    if (std.mem.eql(u8, command, "migrate-segmented")) {
        return runSegmentedMigration(allocator, environment, argv);
    }
    return error.UnknownCommand;
}

fn isOperationCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "validate") or
        std.mem.eql(u8, command, "materialize") or
        std.mem.eql(u8, command, "transact") or
        std.mem.eql(u8, command, "project") or
        std.mem.eql(u8, command, "doctor") or
        std.mem.eql(u8, command, "migrate-segmented");
}

fn runRecoveryCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !u8 {
    if (argv.len == 0) return error.MissingRecoveryAction;
    if (!std.mem.eql(u8, argv[0], "inspect") and
        !std.mem.eql(u8, argv[0], "reclaim"))
    {
        return error.UnknownRecoveryAction;
    }
    if (isOnlyHelp(argv[1..])) {
        try writeStdout(Help);
        return 0;
    }
    const reclaim = std.mem.eql(u8, argv[0], "reclaim");
    const args = try parseRecoveryArgs(argv[1..], reclaim);
    try validateRecoveryTransactionId(args.transaction_id);
    var paths = try RecoveryPaths.init(
        allocator,
        args.repo_path,
        args.transaction_id,
    );
    defer paths.deinit(allocator);
    return if (reclaim)
        runRecoveryReclaim(allocator, args, paths)
    else
        runRecoveryInspection(allocator, args.format, paths);
}

fn runRecoveryInspection(
    allocator: std.mem.Allocator,
    format: Format,
    paths: RecoveryPaths,
) !u8 {
    const candidates = try durable_store.inspectLegacyLeaseRecoveryCandidates(
        allocator,
        paths.transaction_dir,
        .{ .shared = paths.counter_path },
    );
    defer durable_store.deinitLegacyLeaseRecoveryCandidates(
        allocator,
        candidates,
    );
    try emitRecoveryInspection(format, candidates);
    return 0;
}

fn runRecoveryReclaim(
    allocator: std.mem.Allocator,
    args: RecoveryArgs,
    paths: RecoveryPaths,
) !u8 {
    var summary: durable_store.TransactionRecoverySummary = .{};
    const receipt = durable_store.reclaimLegacyLease(
        allocator,
        paths.transaction_dir,
        .{ .shared = paths.counter_path },
        .{
            .transaction_id = args.transaction_id,
            .resource = args.resource.?,
            .lock_id = args.lock_id.?,
            .fencing_token = args.fencing_token.?,
            .confirm_no_legacy_writers = args.confirm_no_legacy_writers,
        },
        &summary,
    ) catch |err| {
        try emitRecoveryError(err, summary.storage_mutated);
        return 2;
    };
    defer {
        allocator.free(receipt.lock_id);
        allocator.free(receipt.resource);
        allocator.free(receipt.result);
    }
    emitRecoveryReclaim(args.format, receipt) catch |err| {
        try emitRecoveryError(err, summary.storage_mutated);
        return 2;
    };
    return 0;
}

fn runTransact(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    var args = try parseTransactionArgs(allocator, argv);
    defer args.deinit(allocator);
    var context = try loadDefinition(
        allocator,
        environment,
        args.common.definition_path,
        .{ .kind = .transact, .name = args.operation },
    );
    defer context.deinit(allocator);
    var bindings = try bindParameters(
        allocator,
        &context.definition_plan.parameter_declarations,
        args.common.parameter_specs,
    );
    defer bindings.deinit(allocator);
    const owned_documents = try readDocuments(
        allocator,
        &context.validation_plan.?,
        args.common.input_specs,
    );
    defer deinitDocuments(allocator, owned_documents);
    const documents = try documentViews(allocator, owned_documents);
    defer allocator.free(documents);
    try durable_store.rejectSymlinkComponents(args.repo_path);
    const repo_root = try std.Io.Dir.cwd().realPathFileAlloc(
        defaultIo(),
        args.repo_path,
        allocator,
    );
    defer allocator.free(repo_root);
    var result = ledger.transaction.transact(
        allocator,
        &context.definition_plan,
        &context.closure,
        context.entry_path,
        &context.validation_plan.?,
        &context.storage_plan.?,
        if (context.protocol_plan) |*plan| plan else null,
        args.operation,
        repo_root,
        documents,
        &bindings,
    ) catch |err| {
        try emitTransactionError(
            err,
            ledger.transaction.lastMutationState(),
        );
        return 2;
    };
    defer result.deinit(allocator);
    emitTransaction(
        allocator,
        args.common.format,
        &result,
        context.stats,
    ) catch |err| {
        try emitTransactionError(err, result.storage_mutated);
        return 2;
    };
    return if (result.validation_result.valid) 0 else 2;
}

fn runDoctor(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    var args = try parseDoctorArgs(allocator, argv);
    defer args.deinit(allocator);
    var context = try loadDefinition(
        allocator,
        environment,
        args.definition_path,
        .{ .kind = .doctor },
    );
    defer context.deinit(allocator);
    var bindings = try bindParameters(
        allocator,
        &context.definition_plan.parameter_declarations,
        args.parameter_specs,
    );
    defer bindings.deinit(allocator);
    try durable_store.rejectSymlinkComponents(args.repo_path);
    const repo_root = try std.Io.Dir.cwd().realPathFileAlloc(
        defaultIo(),
        args.repo_path,
        allocator,
    );
    defer allocator.free(repo_root);
    var result = try ledger.doctor.execute(
        allocator,
        &context.definition_plan,
        &context.storage_plan.?,
        if (context.protocol_plan) |*plan| plan else null,
        repo_root,
        &bindings,
    );
    defer result.deinit(allocator);
    try emitDoctor(allocator, args.format, &result, context.stats);
    return if (result.healthy) 0 else 2;
}

fn runSegmentedMigration(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    var args = try parseDoctorArgs(allocator, argv);
    defer args.deinit(allocator);
    var context = try loadDefinition(
        allocator,
        environment,
        args.definition_path,
        .{ .kind = .migration },
    );
    defer context.deinit(allocator);
    var bindings = try bindParameters(
        allocator,
        &context.definition_plan.parameter_declarations,
        args.parameter_specs,
    );
    defer bindings.deinit(allocator);
    try durable_store.rejectSymlinkComponents(args.repo_path);
    const repo_root = try std.Io.Dir.cwd().realPathFileAlloc(
        defaultIo(),
        args.repo_path,
        allocator,
    );
    defer allocator.free(repo_root);
    var result = ledger.migration.execute(
        allocator,
        &context.definition_plan,
        &context.closure,
        context.entry_path,
        &context.storage_plan.?,
        if (context.protocol_plan) |*plan| plan else null,
        repo_root,
        &bindings,
    ) catch |err| {
        try emitTransactionError(err, ledger.transaction.lastMutationState());
        return 2;
    };
    defer result.deinit(allocator);
    emitSegmentedMigration(args.format, &result) catch |err| {
        try emitTransactionError(
            err,
            ledger.transaction.lastMutationState(),
        );
        return 2;
    };
    return 0;
}

fn runProject(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    var args = try parseProjectionArgs(allocator, argv);
    defer args.deinit(allocator);
    var context = try loadDefinition(
        allocator,
        environment,
        args.definition_path,
        .{ .kind = .project, .name = args.projection },
    );
    defer context.deinit(allocator);
    var bindings = try bindParameters(
        allocator,
        &context.definition_plan.parameter_declarations,
        args.parameter_specs,
    );
    defer bindings.deinit(allocator);
    try durable_store.rejectSymlinkComponents(args.repo_path);
    const repo_root = try std.Io.Dir.cwd().realPathFileAlloc(
        defaultIo(),
        args.repo_path,
        allocator,
    );
    defer allocator.free(repo_root);
    const compiled_projection = context.projection_plan.?.find(
        args.projection,
    ) orelse return error.UnknownProjection;
    var result = ledger.projection.execute(
        allocator,
        &context.definition_plan,
        &context.storage_plan.?,
        if (context.protocol_plan) |*plan| plan else null,
        &context.projection_plan.?,
        args.projection,
        repo_root,
        &bindings,
    ) catch |err| {
        if (compiled_projection.exit_policy.failure) |exit_code| {
            try emitProjectionError(
                err,
                &context.definition_plan,
                args.projection,
                exit_code,
            );
            return exit_code;
        }
        return err;
    };
    defer result.deinit(allocator);
    try emitProjection(
        allocator,
        args.format,
        args.payload_only,
        &result,
        context.stats,
    );
    return result.exit_code;
}

fn runDefinitionCheck(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    var args = try parseCommonArgs(allocator, argv, false);
    defer args.deinit(allocator);
    var context = loadDefinition(
        allocator,
        environment,
        args.definition_path,
        .{ .kind = .definition_check },
    ) catch |err| {
        try emitDefinitionCheckFailure(args.format, err);
        return 2;
    };
    defer context.deinit(allocator);
    switch (args.format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try output.writer.writeAll(
                "{\"schema\":\"ledger-definition-check-result/v1\",\"definition\":{\"id\":",
            );
            try definition_core.canonical_json.writeCanonicalString(
                &output.writer,
                context.definition_plan.id,
            );
            try output.writer.writeAll(",\"digest\":");
            try definition_core.canonical_json.writeCanonicalString(
                &output.writer,
                context.definition_plan.closure_digest[0..],
            );
            try output.writer.writeAll(",\"abi\":\"");
            try output.writer.writeAll(ledger.definition.abi);
            try output.writer.writeAll(
                "\"},\"valid\":true,\"errors\":[],\"compile_stats\":",
            );
            try ledger.envelope.writeCompileStatsJson(
                &output.writer,
                context.stats,
            );
            try output.writer.writeAll(
                ",\"passive\":true,\"authority_granted\":false}\n",
            );
            try writeStdout(output.written());
        },
        .text => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print(
                "structurally valid definition {s}@{s}\n",
                .{
                    context.definition_plan.id,
                    context.definition_plan.closure_digest[0..],
                },
            );
        },
    }
    return 0;
}

fn emitDefinitionCheckFailure(format: Format, err: anyerror) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    if (format == .text) {
        try stdout_writer.interface.print(
            "structurally invalid definition: {s}\n",
            .{@errorName(err)},
        );
        return;
    }
    try stdout_writer.interface.writeAll(
        "{\"schema\":\"ledger-definition-check-result/v1\"," ++
            "\"definition\":null,\"valid\":false,\"errors\":[{\"code\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        &stdout_writer.interface,
        @errorName(err),
    );
    try stdout_writer.interface.writeAll(
        "}],\"compile_stats\":null,\"passive\":false," ++
            "\"authority_granted\":false}\n",
    );
}

fn runDefinitionDescribe(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    var args = try parseCommonArgs(allocator, argv, false);
    defer args.deinit(allocator);
    var context = try loadDefinition(
        allocator,
        environment,
        args.definition_path,
        .{ .kind = .definition },
    );
    defer context.deinit(allocator);
    switch (args.format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try ledger.envelope.writeDefinitionDescriptionJson(
                &output.writer,
                &context.definition_plan,
                context.stats,
            );
            try output.writer.writeByte('\n');
            try writeStdout(output.written());
        },
        .text => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print(
                "{s}\nowner: {s}\ndigest: {s}\nabi: {s}\n",
                .{
                    context.definition_plan.id,
                    context.definition_plan.owner,
                    context.definition_plan.closure_digest[0..],
                    ledger.definition.abi,
                },
            );
        },
    }
    return 0;
}

fn runValidate(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    var args = try parseCommonArgs(allocator, argv, true);
    defer args.deinit(allocator);
    var context = try loadDefinition(
        allocator,
        environment,
        args.definition_path,
        .{ .kind = .validation },
    );
    defer context.deinit(allocator);
    var bindings = try bindProvidedParameters(
        allocator,
        &context.definition_plan.parameter_declarations,
        args.parameter_specs,
    );
    defer bindings.deinit(allocator);
    const owned_documents = try readDocuments(
        allocator,
        &context.validation_plan.?,
        args.input_specs,
    );
    defer deinitDocuments(allocator, owned_documents);
    const documents = try documentViews(allocator, owned_documents);
    defer allocator.free(documents);
    var result = try ledger.materialization.validateArtifact(
        allocator,
        &context.definition_plan,
        &context.validation_plan.?,
        &context.materialization_plan.?,
        documents,
    );
    defer result.deinit(allocator);
    try emitValidation(allocator, args.format, &result, context.stats);
    return if (result.valid) 0 else 2;
}

fn runMaterialize(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    var args = try parseCommonArgs(allocator, argv, true);
    defer args.deinit(allocator);
    var context = try loadDefinition(
        allocator,
        environment,
        args.definition_path,
        .{ .kind = .materialization },
    );
    defer context.deinit(allocator);
    var bindings = try bindProvidedParameters(
        allocator,
        &context.definition_plan.parameter_declarations,
        args.parameter_specs,
    );
    defer bindings.deinit(allocator);
    const owned_documents = try readDocuments(
        allocator,
        &context.validation_plan.?,
        args.input_specs,
    );
    defer deinitDocuments(allocator, owned_documents);
    const documents = try documentViews(allocator, owned_documents);
    defer allocator.free(documents);
    var result = try ledger.materialization.materialize(
        allocator,
        &context.definition_plan,
        &context.validation_plan.?,
        &context.materialization_plan.?,
        documents,
    );
    defer result.deinit(allocator);
    try emitMaterialization(
        allocator,
        args.format,
        &result,
        context.stats,
    );
    return if (result.validation_result.valid) 0 else 2;
}

fn parseCommonArgs(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    allow_inputs: bool,
) !CommonArgs {
    var definition_path: ?[]const u8 = null;
    var format: Format = .json;
    var format_seen = false;
    var inputs: std.ArrayList([]const u8) = .empty;
    errdefer inputs.deinit(allocator);
    var parameters: std.ArrayList([]const u8) = .empty;
    errdefer parameters.deinit(allocator);
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (std.mem.eql(u8, token, "--definition")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (definition_path != null) return error.DuplicateDefinitionOption;
            definition_path = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (format_seen) return error.DuplicateFormatOption;
            format_seen = true;
            format = try Format.parse(argv[index]);
            continue;
        }
        if (allow_inputs and std.mem.eql(u8, token, "--input")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            try inputs.append(allocator, argv[index]);
            continue;
        }
        if (allow_inputs and std.mem.eql(u8, token, "--param")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            try parameters.append(allocator, argv[index]);
            continue;
        }
        return error.UnknownOption;
    }
    if (!allow_inputs and (inputs.items.len != 0 or parameters.items.len != 0)) {
        return error.UnsupportedOption;
    }
    const resolved_definition_path = definition_path orelse return error.MissingDefinition;
    const input_specs = try inputs.toOwnedSlice(allocator);
    errdefer allocator.free(input_specs);
    const parameter_specs = try parameters.toOwnedSlice(allocator);
    return .{
        .definition_path = resolved_definition_path,
        .format = format,
        .input_specs = input_specs,
        .parameter_specs = parameter_specs,
    };
}

fn parseTransactionArgs(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !TransactionArgs {
    var definition_path: ?[]const u8 = null;
    var operation: ?[]const u8 = null;
    var repo_path: ?[]const u8 = null;
    var format: Format = .json;
    var format_seen = false;
    var inputs: std.ArrayList([]const u8) = .empty;
    errdefer inputs.deinit(allocator);
    var parameters: std.ArrayList([]const u8) = .empty;
    errdefer parameters.deinit(allocator);
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (std.mem.eql(u8, token, "--definition")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (definition_path != null) return error.DuplicateDefinitionOption;
            definition_path = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--operation")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (operation != null) return error.DuplicateOperationOption;
            operation = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--repo")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (repo_path != null) return error.DuplicateRepositoryOption;
            repo_path = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (format_seen) return error.DuplicateFormatOption;
            format_seen = true;
            format = try Format.parse(argv[index]);
            continue;
        }
        if (std.mem.eql(u8, token, "--input")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            try inputs.append(allocator, argv[index]);
            continue;
        }
        if (std.mem.eql(u8, token, "--param")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            try parameters.append(allocator, argv[index]);
            continue;
        }
        return error.UnknownOption;
    }
    return finishTransactionArgs(
        allocator,
        definition_path,
        operation,
        repo_path,
        format,
        &inputs,
        &parameters,
    );
}

fn finishTransactionArgs(
    allocator: std.mem.Allocator,
    definition_path: ?[]const u8,
    operation: ?[]const u8,
    repo_path: ?[]const u8,
    format: Format,
    inputs: *std.ArrayList([]const u8),
    parameters: *std.ArrayList([]const u8),
) !TransactionArgs {
    const resolved_definition = definition_path orelse
        return error.MissingDefinition;
    const resolved_operation = operation orelse return error.MissingOperation;
    const resolved_repo = repo_path orelse return error.MissingRepository;
    const input_specs = try inputs.toOwnedSlice(allocator);
    errdefer allocator.free(input_specs);
    const parameter_specs = try parameters.toOwnedSlice(allocator);
    return .{
        .common = .{
            .definition_path = resolved_definition,
            .format = format,
            .input_specs = input_specs,
            .parameter_specs = parameter_specs,
        },
        .operation = resolved_operation,
        .repo_path = resolved_repo,
    };
}

fn parseProjectionArgs(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !ProjectionArgs {
    var definition_path: ?[]const u8 = null;
    var projection: ?[]const u8 = null;
    var repo_path: ?[]const u8 = null;
    var format: ProjectionFormat = .json;
    var payload_only = false;
    var parameters: std.ArrayList([]const u8) = .empty;
    errdefer parameters.deinit(allocator);
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (std.mem.eql(u8, token, "--definition")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (definition_path != null) return error.DuplicateDefinitionOption;
            definition_path = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--projection")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (projection != null) return error.DuplicateProjectionOption;
            projection = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--repo")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (repo_path != null) return error.DuplicateRepositoryOption;
            repo_path = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            format = try ProjectionFormat.parse(argv[index]);
            continue;
        }
        if (std.mem.eql(u8, token, "--param")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            try parameters.append(allocator, argv[index]);
            continue;
        }
        if (std.mem.eql(u8, token, "--payload-only")) {
            if (payload_only) return error.DuplicatePayloadOnlyOption;
            payload_only = true;
            continue;
        }
        return error.UnknownOption;
    }
    if (payload_only and format != .json) {
        return error.PayloadOnlyRequiresJson;
    }
    return .{
        .definition_path = definition_path orelse return error.MissingDefinition,
        .projection = projection orelse return error.MissingProjection,
        .repo_path = repo_path orelse return error.MissingRepository,
        .format = format,
        .parameter_specs = try parameters.toOwnedSlice(allocator),
        .payload_only = payload_only,
    };
}

fn parseDoctorArgs(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !DoctorArgs {
    var definition_path: ?[]const u8 = null;
    var repo_path: ?[]const u8 = null;
    var format: Format = .json;
    var format_seen = false;
    var parameters: std.ArrayList([]const u8) = .empty;
    errdefer parameters.deinit(allocator);
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (std.mem.eql(u8, token, "--definition")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (definition_path != null) return error.DuplicateDefinitionOption;
            definition_path = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--repo")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (repo_path != null) return error.DuplicateRepositoryOption;
            repo_path = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (format_seen) return error.DuplicateFormatOption;
            format_seen = true;
            format = try Format.parse(argv[index]);
            continue;
        }
        if (std.mem.eql(u8, token, "--param")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            try parameters.append(allocator, argv[index]);
            continue;
        }
        return error.UnknownOption;
    }
    return .{
        .definition_path = definition_path orelse return error.MissingDefinition,
        .repo_path = repo_path orelse return error.MissingRepository,
        .format = format,
        .parameter_specs = try parameters.toOwnedSlice(allocator),
    };
}

fn parseRecoveryArgs(
    argv: []const []const u8,
    reclaim: bool,
) !RecoveryArgs {
    var repo_path: ?[]const u8 = null;
    var transaction_id: ?[]const u8 = null;
    var resource: ?[]const u8 = null;
    var lock_id: ?[]const u8 = null;
    var fencing_token: ?u64 = null;
    var confirm_no_legacy_writers = false;
    var format: Format = .json;
    var format_seen = false;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (std.mem.eql(u8, token, "--repo")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (repo_path != null) return error.DuplicateRepositoryOption;
            repo_path = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--transaction")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (transaction_id != null) {
                return error.DuplicateTransactionOption;
            }
            transaction_id = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--lock-id")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (lock_id != null) return error.DuplicateLockIdOption;
            lock_id = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--resource")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (resource != null) return error.DuplicateResourceOption;
            resource = argv[index];
            continue;
        }
        if (std.mem.eql(
            u8,
            token,
            "--confirm-no-legacy-writers",
        )) {
            if (confirm_no_legacy_writers) {
                return error.DuplicateConfirmationOption;
            }
            confirm_no_legacy_writers = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--fencing-token")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (fencing_token != null) {
                return error.DuplicateFencingTokenOption;
            }
            fencing_token = std.fmt.parseUnsigned(
                u64,
                argv[index],
                10,
            ) catch return error.InvalidFencingToken;
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (format_seen) return error.DuplicateFormatOption;
            format_seen = true;
            format = try Format.parse(argv[index]);
            continue;
        }
        return error.UnknownOption;
    }
    return finishRecoveryArgs(
        repo_path,
        transaction_id,
        resource,
        lock_id,
        fencing_token,
        confirm_no_legacy_writers,
        format,
        reclaim,
    );
}

fn finishRecoveryArgs(
    repo_path: ?[]const u8,
    transaction_id: ?[]const u8,
    resource: ?[]const u8,
    lock_id: ?[]const u8,
    fencing_token: ?u64,
    confirm_no_legacy_writers: bool,
    format: Format,
    reclaim: bool,
) !RecoveryArgs {
    if (!reclaim and
        (resource != null or
            lock_id != null or
            fencing_token != null or
            confirm_no_legacy_writers))
    {
        return error.UnsupportedOption;
    }
    if (reclaim and resource == null) return error.MissingResource;
    if (reclaim and lock_id == null) return error.MissingLockId;
    if (reclaim and fencing_token == null) return error.MissingFencingToken;
    return .{
        .repo_path = repo_path orelse return error.MissingRepository,
        .transaction_id = transaction_id orelse
            return error.MissingTransaction,
        .resource = resource,
        .lock_id = lock_id,
        .fencing_token = fencing_token,
        .confirm_no_legacy_writers = confirm_no_legacy_writers,
        .format = format,
    };
}

fn validateRecoveryTransactionId(transaction_id: []const u8) !void {
    const prefix = "dtx-";
    if (!std.mem.startsWith(u8, transaction_id, prefix) or
        transaction_id.len == prefix.len)
    {
        return error.InvalidTransaction;
    }
    const suffix_separator = std.mem.lastIndexOfScalar(
        u8,
        transaction_id,
        '-',
    ) orelse return error.InvalidTransaction;
    if (suffix_separator == prefix.len - 1) {
        for (transaction_id[prefix.len..]) |byte| {
            if (!std.ascii.isDigit(byte)) {
                return error.InvalidTransaction;
            }
        }
        return;
    }
    if (suffix_separator <= prefix.len or
        transaction_id.len - suffix_separator - 1 != 32)
    {
        return error.InvalidTransaction;
    }
    for (transaction_id[prefix.len..suffix_separator]) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidTransaction;
    }
    for (transaction_id[suffix_separator + 1 ..]) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
            return error.InvalidTransaction;
        }
    }
}

fn loadDefinition(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    path: []const u8,
    route: ledger.compiled_plan.Route,
) !DefinitionContext {
    const absolute = try absoluteDefinitionPathAlloc(allocator, path);
    defer allocator.free(absolute);
    const package_location =
        try definition_core.closure.admittedPackageLocation(
            absolute,
            "skills",
        );
    const cwd = if (package_location == null)
        try std.Io.Dir.cwd().realPathFileAlloc(
            defaultIo(),
            ".",
            allocator,
        )
    else
        null;
    defer if (cwd) |owned| allocator.free(owned);
    const location = package_location orelse
        try definition_core.closure.admittedLocation(
            absolute,
            cwd.?,
            "skills",
        );
    const cache_dir = try ledgerCacheDirAlloc(allocator, environment);
    defer if (cache_dir) |owned| allocator.free(owned);
    return ledger.compiled_plan.load(
        allocator,
        location.root,
        location.entry,
        route,
        Version,
        .{ .cache_dir = cache_dir },
    );
}

fn absoluteDefinitionPathAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(allocator, &.{path});
    }
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(
        defaultIo(),
        ".",
        allocator,
    );
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn ledgerCacheDirAlloc(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
) !?[]u8 {
    var base: []const u8 = undefined;
    var suffix: []const u8 = undefined;
    if (environmentValue(environment, "LEDGER_CACHE_DIR")) |value| {
        base = value;
        suffix = "definitions";
    } else if (environmentValue(environment, "XDG_CACHE_HOME")) |value| {
        base = value;
        suffix = "ledger/definitions";
    } else if (environmentValue(environment, "HOME")) |value| {
        base = value;
        suffix = ".cache/ledger/definitions";
    } else {
        return null;
    }
    const joined = try std.fs.path.join(allocator, &.{ base, suffix });
    defer allocator.free(joined);
    if (std.fs.path.isAbsolute(joined)) {
        return try allocator.dupe(u8, joined);
    }
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(
        defaultIo(),
        ".",
        allocator,
    );
    defer allocator.free(cwd);
    return try std.fs.path.resolve(allocator, &.{ cwd, joined });
}

fn environmentValue(
    environment: *const std.process.Environ.Map,
    key: []const u8,
) ?[]const u8 {
    const value = environment.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

fn readDocuments(
    allocator: std.mem.Allocator,
    plan: *const ledger.validation.Plan,
    specs: []const []const u8,
) ![]OwnedDocument {
    var documents: std.ArrayList(OwnedDocument) = .empty;
    errdefer {
        for (documents.items) |*document| document.deinit(allocator);
        documents.deinit(allocator);
    }
    var stdin_used = false;
    for (specs) |spec| {
        const separator = std.mem.indexOfScalar(u8, spec, '=') orelse
            return error.InvalidInputBinding;
        if (separator == 0 or separator + 1 >= spec.len) return error.InvalidInputBinding;
        const name = spec[0..separator];
        const source = spec[separator + 1 ..];
        const input_index = findValidationInput(plan, name) orelse
            return error.UnknownInputBinding;
        const limit = plan.inputs[input_index].max_bytes;
        const bytes = if (std.mem.eql(u8, source, "-")) blk: {
            if (stdin_used) return error.MultipleStdinInputs;
            stdin_used = true;
            var stdin_reader = std.Io.File.stdin().reader(defaultIo(), &.{});
            break :blk try stdin_reader.interface.allocRemaining(
                allocator,
                .limited(limit),
            );
        } else try std.Io.Dir.cwd().readFileAlloc(
            defaultIo(),
            source,
            allocator,
            .limited(limit),
        );
        {
            errdefer allocator.free(bytes);
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            try documents.append(allocator, .{
                .name = owned_name,
                .bytes = bytes,
            });
        }
    }
    return documents.toOwnedSlice(allocator);
}

fn documentViews(
    allocator: std.mem.Allocator,
    owned: []const OwnedDocument,
) ![]ledger.validation.InputDocument {
    const documents = try allocator.alloc(ledger.validation.InputDocument, owned.len);
    for (owned, 0..) |document, index| {
        documents[index] = .{ .name = document.name, .bytes = document.bytes };
    }
    return documents;
}

fn deinitDocuments(
    allocator: std.mem.Allocator,
    documents: []OwnedDocument,
) void {
    for (documents) |*document| document.deinit(allocator);
    allocator.free(documents);
}

fn bindParameters(
    allocator: std.mem.Allocator,
    declarations: *const definition_core.parameters.Declarations,
    specs: []const []const u8,
) !definition_core.parameters.Bindings {
    const inputs = try parameterInputs(allocator, specs);
    defer allocator.free(inputs);
    return definition_core.parameters.bind(allocator, declarations, inputs);
}

fn bindProvidedParameters(
    allocator: std.mem.Allocator,
    declarations: *const definition_core.parameters.Declarations,
    specs: []const []const u8,
) !definition_core.parameters.Bindings {
    const inputs = try parameterInputs(allocator, specs);
    defer allocator.free(inputs);
    return definition_core.parameters.bindProvided(
        allocator,
        declarations,
        inputs,
    );
}

fn parameterInputs(
    allocator: std.mem.Allocator,
    specs: []const []const u8,
) ![]definition_core.parameters.Input {
    const inputs = try allocator.alloc(
        definition_core.parameters.Input,
        specs.len,
    );
    errdefer allocator.free(inputs);
    for (specs, 0..) |spec, index| {
        const separator = std.mem.indexOfScalar(u8, spec, '=') orelse
            return error.InvalidParameterBinding;
        if (separator == 0 or separator + 1 >= spec.len) {
            return error.InvalidParameterBinding;
        }
        inputs[index] = .{
            .name = spec[0..separator],
            .raw_value = spec[separator + 1 ..],
        };
    }
    return inputs;
}

fn emitValidation(
    allocator: std.mem.Allocator,
    format: Format,
    result: *const ledger.validation.Result,
    compile_stats: definition_core.result.CompileStats,
) !void {
    return switch (format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try ledger.envelope.writeValidationJson(
                &output.writer,
                result,
                compile_stats,
            );
            try output.writer.writeByte('\n');
            try writeStdout(output.written());
        },
        .text => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print(
                "{s} under {s}@{s}\n",
                .{
                    if (result.valid) "structurally valid" else "structurally invalid",
                    result.definition_id,
                    result.definition_digest[0..],
                },
            );
        },
    };
}

fn emitMaterialization(
    allocator: std.mem.Allocator,
    format: Format,
    result: *const ledger.materialization.Result,
    compile_stats: definition_core.result.CompileStats,
) !void {
    return switch (format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try ledger.envelope.writeMaterializationJson(
                &output.writer,
                result,
                compile_stats,
            );
            try output.writer.writeByte('\n');
            try writeStdout(output.written());
        },
        .text => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            if (result.validation_result.valid) {
                try stdout_writer.interface.print(
                    "materialized {s}@{s}\n",
                    .{
                        result.validation_result.definition_id,
                        result.validation_result.definition_digest[0..],
                    },
                );
            } else {
                try stdout_writer.interface.writeAll("structurally invalid; not materialized\n");
            }
        },
    };
}

fn emitTransaction(
    allocator: std.mem.Allocator,
    format: Format,
    result: *const ledger.transaction.Result,
    compile_stats: definition_core.result.CompileStats,
) !void {
    switch (format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try ledger.envelope.writeTransactionJson(
                &output.writer,
                result,
                compile_stats,
            );
            try output.writer.writeByte('\n');
            try writeStdout(output.written());
        },
        .text => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print(
                "{s} {s}@{s}; storage_mutated={s}\n",
                .{
                    result.operation,
                    result.validation_result.definition_id,
                    result.validation_result.definition_digest[0..],
                    if (result.storage_mutated) "true" else "false",
                },
            );
        },
    }
}

fn emitTransactionError(err: anyerror, storage_mutated: ?bool) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try ledger.envelope.writeTransactionErrorJson(
        &stdout_writer.interface,
        err,
        storage_mutated,
    );
    try stdout_writer.interface.writeByte('\n');
}

fn emitProjection(
    allocator: std.mem.Allocator,
    format: ProjectionFormat,
    payload_only: bool,
    result: *const ledger.projection.Result,
    compile_stats: definition_core.result.CompileStats,
) !void {
    if (payload_only) {
        return emitProjectionPayload(result.payload);
    }
    return switch (format) {
        .json => emitProjectionJson(allocator, result, compile_stats),
        .text => emitProjectionText(allocator, result.payload),
        .jsonl, .table, .markdown => emitRenderedProjection(
            allocator,
            format,
            result,
        ),
    };
}

fn emitProjectionPayload(payload: []const u8) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(payload);
    try stdout_writer.interface.writeByte('\n');
}

fn emitProjectionJson(
    allocator: std.mem.Allocator,
    result: *const ledger.projection.Result,
    compile_stats: definition_core.result.CompileStats,
) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try ledger.envelope.writeProjectionJson(
        &output.writer,
        result,
        compile_stats,
    );
    try output.writer.writeByte('\n');
    try writeStdout(output.written());
}

fn emitProjectionText(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        payload,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch {
        try stdout_writer.interface.writeAll(payload);
        try stdout_writer.interface.writeByte('\n');
        return;
    };
    defer parsed.deinit();
    const text = if (parsed.value == .string)
        parsed.value.string
    else
        payload;
    try stdout_writer.interface.writeAll(text);
    try stdout_writer.interface.writeByte('\n');
}

fn emitRenderedProjection(
    allocator: std.mem.Allocator,
    format: ProjectionFormat,
    result: *const ledger.projection.Result,
) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        result.payload,
        .{ .duplicate_field_behavior = .@"error" },
    );
    defer parsed.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    switch (format) {
        .jsonl => try writeProjectionJsonl(
            allocator,
            &output.writer,
            parsed.value,
        ),
        .table, .markdown => try writeProjectionTable(
            allocator,
            &output,
            parsed.value,
            format == .markdown,
            result.max_output_bytes,
        ),
        else => return error.InvalidFormat,
    }
    if (output.written().len > result.max_output_bytes) {
        return error.OutputBytesExceeded;
    }
    try writeStdout(output.written());
}

fn writeProjectionJsonl(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: std.json.Value,
) !void {
    if (value == .array) {
        for (value.array.items) |item| {
            try definition_core.canonical_json.writeCanonicalJson(
                allocator,
                writer,
                item,
            );
            try writer.writeByte('\n');
        }
        return;
    }
    try definition_core.canonical_json.writeCanonicalJson(
        allocator,
        writer,
        value,
    );
    try writer.writeByte('\n');
}

fn writeProjectionTable(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    value: std.json.Value,
    markdown: bool,
    max_output_bytes: usize,
) !void {
    switch (value) {
        .array => |array| return writeProjectionArrayTable(
            allocator,
            output,
            array.items,
            markdown,
            max_output_bytes,
        ),
        .object => |object| return writeProjectionObjectTable(
            allocator,
            output,
            value,
            object,
            markdown,
            max_output_bytes,
        ),
        else => {
            try writeTableHeader(
                output,
                &.{"value"},
                markdown,
                max_output_bytes,
            );
            try writeTableRow(
                allocator,
                output,
                &.{value},
                markdown,
                max_output_bytes,
            );
        },
    }
}

fn writeProjectionArrayTable(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    items: []const std.json.Value,
    markdown: bool,
    max_output_bytes: usize,
) !void {
    if (items.len == 0) return;
    const object_rows = for (items) |item| {
        if (item != .object) break false;
    } else true;
    if (!object_rows) {
        try validateTableCellCount(items.len, 1);
        try writeTableHeader(
            output,
            &.{"value"},
            markdown,
            max_output_bytes,
        );
        for (items) |item| {
            try writeTableRow(
                allocator,
                output,
                &.{item},
                markdown,
                max_output_bytes,
            );
        }
        return;
    }
    const keys = try collectTableKeys(allocator, items);
    defer allocator.free(keys);
    try validateTableCellCount(items.len, keys.len);
    try writeTableHeader(output, keys, markdown, max_output_bytes);
    for (items) |item| {
        try writeObjectTableRow(
            allocator,
            output,
            item.object,
            keys,
            markdown,
            max_output_bytes,
        );
    }
}

fn writeProjectionObjectTable(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    value: std.json.Value,
    object: std.json.ObjectMap,
    markdown: bool,
    max_output_bytes: usize,
) !void {
    const keys = try collectTableKeys(allocator, &.{value});
    defer allocator.free(keys);
    try validateTableCellCount(keys.len, 2);
    try writeTableHeader(
        output,
        &.{ "key", "value" },
        markdown,
        max_output_bytes,
    );
    for (keys) |key| {
        if (markdown) try writeBoundedAll(output, "| ", max_output_bytes);
        try writeTableTextCell(output, key, markdown, max_output_bytes);
        try writeTableSeparator(output, markdown, max_output_bytes);
        try writeTableValueCell(
            allocator,
            output,
            object.get(key).?,
            markdown,
            max_output_bytes,
        );
        try writeTableRowEnd(output, markdown, max_output_bytes);
    }
}

fn validateTableCellCount(rows: usize, columns: usize) !void {
    if (columns > max_projection_table_columns) {
        return error.ProjectionTableColumnBoundExceeded;
    }
    const cells = std.math.mul(usize, rows, columns) catch
        return error.ProjectionTableCellBoundExceeded;
    if (cells > max_projection_table_cells) {
        return error.ProjectionTableCellBoundExceeded;
    }
}

fn collectTableKeys(
    allocator: std.mem.Allocator,
    rows: []const std.json.Value,
) ![][]const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer keys.deinit(allocator);
    for (rows) |row| {
        var iterator = row.object.iterator();
        while (iterator.next()) |entry| {
            const result = try seen.getOrPut(allocator, entry.key_ptr.*);
            if (result.found_existing) continue;
            if (keys.items.len >= max_projection_table_columns) {
                return error.ProjectionTableColumnBoundExceeded;
            }
            try keys.append(allocator, entry.key_ptr.*);
        }
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    return keys.toOwnedSlice(allocator);
}

fn writeTableHeader(
    output: *std.Io.Writer.Allocating,
    keys: []const []const u8,
    markdown: bool,
    max_output_bytes: usize,
) !void {
    if (markdown) try writeBoundedAll(output, "| ", max_output_bytes);
    for (keys, 0..) |key, index| {
        if (index != 0) {
            try writeTableSeparator(output, markdown, max_output_bytes);
        }
        try writeTableTextCell(
            output,
            key,
            markdown,
            max_output_bytes,
        );
    }
    try writeTableRowEnd(output, markdown, max_output_bytes);
    if (!markdown) return;
    try writeBoundedAll(output, "| ", max_output_bytes);
    for (keys, 0..) |_, index| {
        if (index != 0) {
            try writeBoundedAll(output, " | ", max_output_bytes);
        }
        try writeBoundedAll(output, "---", max_output_bytes);
    }
    try writeBoundedAll(output, " |\n", max_output_bytes);
}

fn writeObjectTableRow(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    object: std.json.ObjectMap,
    keys: []const []const u8,
    markdown: bool,
    max_output_bytes: usize,
) !void {
    if (markdown) try writeBoundedAll(output, "| ", max_output_bytes);
    for (keys, 0..) |key, index| {
        if (index != 0) {
            try writeTableSeparator(output, markdown, max_output_bytes);
        }
        if (object.get(key)) |value| {
            try writeTableValueCell(
                allocator,
                output,
                value,
                markdown,
                max_output_bytes,
            );
        }
    }
    try writeTableRowEnd(output, markdown, max_output_bytes);
}

fn writeTableRow(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    values: []const std.json.Value,
    markdown: bool,
    max_output_bytes: usize,
) !void {
    if (markdown) try writeBoundedAll(output, "| ", max_output_bytes);
    for (values, 0..) |value, index| {
        if (index != 0) {
            try writeTableSeparator(output, markdown, max_output_bytes);
        }
        try writeTableValueCell(
            allocator,
            output,
            value,
            markdown,
            max_output_bytes,
        );
    }
    try writeTableRowEnd(output, markdown, max_output_bytes);
}

fn writeTableValueCell(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    value: std.json.Value,
    markdown: bool,
    max_output_bytes: usize,
) !void {
    if (value == .string) {
        return writeTableTextCell(
            output,
            value.string,
            markdown,
            max_output_bytes,
        );
    }
    var canonical: std.Io.Writer.Allocating = .init(allocator);
    defer canonical.deinit();
    try definition_core.canonical_json.writeCanonicalJson(
        allocator,
        &canonical.writer,
        value,
    );
    try writeTableTextCell(
        output,
        canonical.written(),
        markdown,
        max_output_bytes,
    );
}

fn writeTableTextCell(
    output: *std.Io.Writer.Allocating,
    text: []const u8,
    markdown: bool,
    max_output_bytes: usize,
) !void {
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (markdown and byte == '|') {
            try writeBoundedAll(output, "\\|", max_output_bytes);
        } else if (byte == '\n' or byte == '\r') {
            try writeBoundedAll(
                output,
                if (markdown) "<br>" else " ",
                max_output_bytes,
            );
        } else if (byte == '\t') {
            try writeBoundedByte(output, ' ', max_output_bytes);
        } else if (byte < 0x20 or byte == 0x7f) {
            try writeEscapedControl(
                output,
                byte,
                max_output_bytes,
            );
        } else if (byte >= 0x80) {
            const sequence_len = try std.unicode.utf8ByteSequenceLength(byte);
            if (index + sequence_len > text.len) return error.InvalidUtf8;
            const codepoint = try std.unicode.utf8Decode(
                text[index .. index + sequence_len],
            );
            if (codepoint >= 0x80 and codepoint <= 0x9f) {
                try writeEscapedControl(
                    output,
                    codepoint,
                    max_output_bytes,
                );
            } else {
                try writeBoundedAll(
                    output,
                    text[index .. index + sequence_len],
                    max_output_bytes,
                );
            }
            index += sequence_len;
            continue;
        } else {
            try writeBoundedByte(output, byte, max_output_bytes);
        }
        index += 1;
    }
}

fn writeEscapedControl(
    output: *std.Io.Writer.Allocating,
    codepoint: u21,
    max_output_bytes: usize,
) !void {
    var buffer: [6]u8 = undefined;
    const escaped = try std.fmt.bufPrint(
        &buffer,
        "\\u{x:0>4}",
        .{codepoint},
    );
    try writeBoundedAll(output, escaped, max_output_bytes);
}

fn writeTableSeparator(
    output: *std.Io.Writer.Allocating,
    markdown: bool,
    max_output_bytes: usize,
) !void {
    try writeBoundedAll(
        output,
        if (markdown) " | " else "\t",
        max_output_bytes,
    );
}

fn writeTableRowEnd(
    output: *std.Io.Writer.Allocating,
    markdown: bool,
    max_output_bytes: usize,
) !void {
    try writeBoundedAll(
        output,
        if (markdown) " |\n" else "\n",
        max_output_bytes,
    );
}

fn writeBoundedAll(
    output: *std.Io.Writer.Allocating,
    bytes: []const u8,
    max_output_bytes: usize,
) !void {
    const next = std.math.add(
        usize,
        output.written().len,
        bytes.len,
    ) catch return error.OutputBytesExceeded;
    if (next > max_output_bytes) return error.OutputBytesExceeded;
    try output.writer.writeAll(bytes);
}

fn writeBoundedByte(
    output: *std.Io.Writer.Allocating,
    byte: u8,
    max_output_bytes: usize,
) !void {
    if (output.written().len >= max_output_bytes) {
        return error.OutputBytesExceeded;
    }
    try output.writer.writeByte(byte);
}

fn emitProjectionError(
    err: anyerror,
    definition_plan: *const ledger.definition.Plan,
    projection: []const u8,
    exit_code: u8,
) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(
        "{\"schema\":\"ledger-projection-error/v1\",\"definition\":{\"id\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        &stdout_writer.interface,
        definition_plan.id,
    );
    try stdout_writer.interface.writeAll(",\"digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        &stdout_writer.interface,
        &definition_plan.closure_digest,
    );
    try stdout_writer.interface.writeAll(",\"abi\":\"");
    try stdout_writer.interface.writeAll(ledger.definition.abi);
    try stdout_writer.interface.writeAll("\"},\"projection\":");
    try definition_core.canonical_json.writeCanonicalString(
        &stdout_writer.interface,
        projection,
    );
    try stdout_writer.interface.writeAll(",\"code\":");
    try definition_core.canonical_json.writeCanonicalString(
        &stdout_writer.interface,
        @errorName(err),
    );
    try stdout_writer.interface.print(
        ",\"exit_code\":{d},\"authority_granted\":false,\"storage_mutated\":false}}\n",
        .{exit_code},
    );
}

fn emitDoctor(
    allocator: std.mem.Allocator,
    format: Format,
    result: *const ledger.doctor.Result,
    compile_stats: definition_core.result.CompileStats,
) !void {
    switch (format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try ledger.envelope.writeDoctorJson(
                &output.writer,
                result,
                compile_stats,
            );
            try output.writer.writeByte('\n');
            try writeStdout(output.written());
        },
        .text => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print(
                "{s} {s}@{s}; pending_transactions={d}\n",
                .{
                    if (result.healthy) "healthy" else "unhealthy",
                    result.definition_id,
                    result.definition_digest[0..],
                    result.pending_transactions,
                },
            );
        },
    }
}

fn emitSegmentedMigration(
    format: Format,
    result: *const ledger.migration.Result,
) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    switch (format) {
        .json => {
            try stdout_writer.interface.writeAll(
                "{\"schema\":\"ledger-segmented-migration-result/v1\"," ++
                    "\"already_migrated\":",
            );
            try stdout_writer.interface.writeAll(
                if (result.already_migrated) "true" else "false",
            );
            try stdout_writer.interface.writeAll(",\"logical_ref\":");
            try definition_core.canonical_json.writeCanonicalString(
                &stdout_writer.interface,
                result.logical_ref,
            );
            try stdout_writer.interface.writeAll(",\"records\":");
            try stdout_writer.interface.print("{d}", .{result.records});
            try stdout_writer.interface.writeAll(",\"revision\":");
            try definition_core.canonical_json.writeCanonicalString(
                &stdout_writer.interface,
                result.revision,
            );
            try stdout_writer.interface.writeAll(",\"transaction_id\":");
            if (result.transaction_id) |transaction_id| {
                try definition_core.canonical_json.writeCanonicalString(
                    &stdout_writer.interface,
                    transaction_id,
                );
            } else {
                try stdout_writer.interface.writeAll("null");
            }
            try stdout_writer.interface.writeAll("}\n");
        },
        .text => try stdout_writer.interface.print(
            "{s}: {s} records={d} revision={s}\n",
            .{
                if (result.already_migrated) "already migrated" else "migrated",
                result.logical_ref,
                result.records,
                result.revision,
            },
        ),
    }
}

fn emitCapabilities(argv: []const []const u8) !u8 {
    const format = try parseCapabilitiesFormat(argv);
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    if (format == .text) {
        try stdout_writer.interface.print(
            "Ledger {s}\nABI: {s}\n",
            .{ Version, ledger.definition.abi },
        );
        return 0;
    }
    try emitCapabilitiesJson(&stdout_writer.interface);
    return 0;
}

fn parseCapabilitiesFormat(argv: []const []const u8) !Format {
    var format: Format = .json;
    var format_seen = false;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        if (!std.mem.eql(u8, argv[index], "--format")) return error.UnknownOption;
        index += 1;
        if (index >= argv.len) return error.MissingOptionValue;
        if (format_seen) return error.DuplicateFormatOption;
        format_seen = true;
        format = try Format.parse(argv[index]);
    }
    return format;
}

fn emitCapabilitiesJson(writer: *std.Io.Writer) !void {
    try writer.print(
        "{{\"schema\":\"ledger-capabilities/v1\",\"version\":\"{s}\"," ++
            "\"artifact_abis\":[\"{s}\"],\"operators\":[",
        .{ Version, ledger.definition.abi },
    );
    try writeCapabilityOperators(writer);
    try writeCapabilityTail(writer);
}

fn writeCapabilityOperators(writer: *std.Io.Writer) !void {
    var first = true;
    for (std.enums.values(ledger.definition.Operator)) |operator| {
        if (!operator.supported()) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"id\":");
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            operator.id(),
        );
        try writer.print(
            ",\"version\":{d}}}",
            .{operator.version()},
        );
    }
}

fn writeCapabilityTail(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        "],\"codecs\":[\"json\",\"jsonl\",\"text\"]," ++
            "\"storage_adapters\":[\"pure\",\"addressed-document\",\"event-log\"]," ++
            "\"features\":{\"bounded_checkpoint_replay_v1\":true," ++
            "\"full_history_doctor_v1\":true," ++
            "\"segmented_event_log_v1\":true," ++
            "\"segmented_migration_v1\":true}," ++
            "\"cache_format\":",
    );
    try writer.print(
        "{d}",
        .{definition_core.cache.format_version},
    );
    try writer.print(
        ",\"bounds\":{{\"max_definition_files\":128," ++
            "\"max_definition_bytes\":4194304,\"max_import_depth\":32," ++
            "\"max_event_record_bytes\":{d}," ++
            "\"max_historical_definition_bytes\":{d}," ++
            "\"max_historical_definition_versions\":{d}," ++
            "\"max_projection_table_cells\":{d}," ++
            "\"max_projection_table_columns\":{d}}}," ++
            "\"result_schemas\":[\"ledger-capabilities/v1\"," ++
            "\"ledger-command-error/v1\"," ++
            "\"ledger-definition-check-result/v1\"," ++
            "\"ledger-definition-description/v1\"," ++
            "\"ledger-doctor-result/v1\"," ++
            "\"ledger-materialization-result/v1\"," ++
            "\"ledger-segmented-migration-result/v1\"," ++
            "\"ledger-projection-error/v1\"," ++
            "\"ledger-recovery-inspection/v1\"," ++
            "\"ledger-recovery-reclaim-result/v1\"," ++
            "\"ledger-transaction-result/v1\"," ++
            "\"ledger-transaction-error/v1\"," ++
            "\"ledger-projection-result/v1\"," ++
            "\"ledger-validation-result/v1\"]}}\n",
        .{
            durable_store.max_event_record_bytes,
            ledger.replay.max_historical_definition_bytes,
            ledger.replay.max_historical_definition_versions,
            max_projection_table_cells,
            max_projection_table_columns,
        },
    );
}

fn emitCommandError(err: anyerror) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(
        "{\"schema\":\"ledger-command-error/v1\",\"code\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        &stdout_writer.interface,
        @errorName(err),
    );
    try stdout_writer.interface.writeAll(
        ",\"authority_granted\":false,\"storage_mutated\":false}\n",
    );
}

fn emitRecoveryInspection(
    format: Format,
    candidates: []const durable_store.LegacyLeaseRecoveryCandidate,
) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    switch (format) {
        .json => {
            try stdout_writer.interface.writeAll(
                "{\"schema\":\"ledger-recovery-inspection/v1\"," ++
                    "\"authority_granted\":false," ++
                    "\"storage_mutated\":false,\"candidates\":[",
            );
            for (candidates, 0..) |candidate, index| {
                if (index != 0) try stdout_writer.interface.writeByte(',');
                try candidate.writeJson(&stdout_writer.interface);
            }
            try stdout_writer.interface.writeAll("]}\n");
        },
        .text => {
            try stdout_writer.interface.print(
                "legacy lease recovery candidates: {d}\n",
                .{candidates.len},
            );
            for (candidates) |candidate| {
                try stdout_writer.interface.writeAll("transaction=");
                try std.json.Stringify.value(
                    candidate.transaction_id,
                    .{},
                    &stdout_writer.interface,
                );
                try stdout_writer.interface.writeAll(" lock_id=");
                try std.json.Stringify.value(
                    candidate.lock_id,
                    .{},
                    &stdout_writer.interface,
                );
                try stdout_writer.interface.print(
                    " fencing_token={d} resource=",
                    .{candidate.fencing_token},
                );
                try std.json.Stringify.value(
                    candidate.resource,
                    .{},
                    &stdout_writer.interface,
                );
                try stdout_writer.interface.print(
                    " kind={s}",
                    .{@tagName(candidate.kind)},
                );
                try stdout_writer.interface.writeAll(" expires_at=");
                try std.json.Stringify.value(
                    candidate.expires_at,
                    .{},
                    &stdout_writer.interface,
                );
                try stdout_writer.interface.writeByte('\n');
            }
        },
    }
}

fn emitRecoveryReclaim(
    format: Format,
    receipt: durable_store.ReclaimReceipt,
) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    switch (format) {
        .json => {
            try stdout_writer.interface.writeAll(
                "{\"schema\":\"ledger-recovery-reclaim-result/v1\"," ++
                    "\"authority_granted\":false," ++
                    "\"storage_mutated\":true,\"result\":",
            );
            try receipt.writeJson(&stdout_writer.interface);
            try stdout_writer.interface.writeAll("}\n");
        },
        .text => {
            try stdout_writer.interface.writeAll("reclaimed legacy lease ");
            try std.json.Stringify.value(
                receipt.lock_id,
                .{},
                &stdout_writer.interface,
            );
            try stdout_writer.interface.writeAll(" for ");
            try std.json.Stringify.value(
                receipt.resource,
                .{},
                &stdout_writer.interface,
            );
            try stdout_writer.interface.print(
                "; fencing authority advanced from {d} to {d}\n",
                .{
                    receipt.previous_fencing_token,
                    receipt.authority_counter,
                },
            );
        },
    }
}

fn emitRecoveryError(
    err: anyerror,
    storage_mutated: bool,
) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(
        "{\"schema\":\"ledger-command-error/v1\",\"code\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        &stdout_writer.interface,
        @errorName(err),
    );
    try stdout_writer.interface.print(
        ",\"authority_granted\":false,\"storage_mutated\":{s}}}\n",
        .{if (storage_mutated) "true" else "false"},
    );
}

fn findValidationInput(
    plan: *const ledger.validation.Plan,
    name: []const u8,
) ?usize {
    for (plan.inputs, 0..) |input, index| {
        if (std.mem.eql(u8, input.name, name)) return index;
    }
    return null;
}

fn defaultIo() std.Io {
    return runtime_io orelse std.Io.Threaded.global_single_threaded.io();
}

fn writeStdout(bytes: []const u8) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(bytes);
}

fn isClosedPipe(err: anyerror) bool {
    return err == error.WriteFailed or err == error.BrokenPipe;
}

fn isHelp(token: []const u8) bool {
    return std.mem.eql(u8, token, "-h") or std.mem.eql(u8, token, "--help");
}

fn isOnlyHelp(argv: []const []const u8) bool {
    return argv.len == 1 and isHelp(argv[0]);
}

fn isVersion(token: []const u8) bool {
    return std.mem.eql(u8, token, "-V") or std.mem.eql(u8, token, "--version");
}

test "final command surface excludes source and positional contract routing" {
    try std.testing.expect(std.mem.indexOf(u8, Help, "--source") == null);
    try std.testing.expect(std.mem.indexOf(u8, Help, "capture") == null);
    try std.testing.expect(std.mem.indexOf(u8, Help, "definition check") != null);
    try std.testing.expect(std.mem.indexOf(u8, Help, "materialize") != null);
}

test "only store-backed commands install durable runtime IO" {
    try std.testing.expect(!requiresDurableIo(&.{}));
    try std.testing.expect(!requiresDurableIo(&.{"ledger"}));
    try std.testing.expect(!requiresDurableIo(&.{ "ledger", "validate" }));
    try std.testing.expect(!requiresDurableIo(&.{ "ledger", "materialize" }));
    try std.testing.expect(!requiresDurableIo(&.{ "ledger", "definition" }));
    try std.testing.expect(requiresDurableIo(&.{ "ledger", "transact" }));
    try std.testing.expect(requiresDurableIo(&.{ "ledger", "project" }));
    try std.testing.expect(requiresDurableIo(&.{ "ledger", "doctor" }));
    try std.testing.expect(requiresDurableIo(&.{
        "ledger",
        "migrate-segmented",
    }));
    try std.testing.expect(requiresDurableIo(&.{ "ledger", "recovery" }));
}

test "recovery parser separates inspection from exact witnessed reclaim" {
    const inspection = try parseRecoveryArgs(&.{
        "--repo",
        "/repo",
        "--transaction",
        "dtx-42",
    }, false);
    try std.testing.expect(inspection.resource == null);
    try std.testing.expect(inspection.lock_id == null);
    try std.testing.expect(inspection.fencing_token == null);
    try std.testing.expect(!inspection.confirm_no_legacy_writers);
    const reclaim = try parseRecoveryArgs(&.{
        "--repo",
        "/repo",
        "--transaction",
        "dtx-42",
        "--resource",
        "/repo/.ledger/events.jsonl",
        "--lock-id",
        "dlk-7-1",
        "--fencing-token",
        "18446744073709551615",
        "--confirm-no-legacy-writers",
    }, true);
    try std.testing.expectEqualStrings(
        "/repo/.ledger/events.jsonl",
        reclaim.resource.?,
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        reclaim.fencing_token.?,
    );
    try std.testing.expect(reclaim.confirm_no_legacy_writers);
    try std.testing.expectError(
        error.MissingResource,
        parseRecoveryArgs(&.{
            "--repo",
            "/repo",
            "--transaction",
            "dtx-42",
            "--lock-id",
            "dlk-7-1",
            "--fencing-token",
            "7",
        }, true),
    );
    try std.testing.expectError(
        error.UnsupportedOption,
        parseRecoveryArgs(&.{
            "--repo",
            "/repo",
            "--transaction",
            "dtx-42",
            "--lock-id",
            "dlk-7-1",
        }, false),
    );
    try std.testing.expectError(
        error.InvalidTransaction,
        validateRecoveryTransactionId("../dtx-42"),
    );
    try validateRecoveryTransactionId(
        "dtx-42-00000000000000000000000000000001",
    );
}

test "recovery paths reject symlinks in generated control components" {
    if (@import("builtin").os.tag == .windows) {
        return error.SkipZigTest;
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    try tmp.dir.createDir(defaultIo(), "repo", .default_dir);
    try tmp.dir.createDir(defaultIo(), "outside", .default_dir);
    try tmp.dir.symLink(
        defaultIo(),
        "../outside",
        "repo/.ledger",
        .{ .is_directory = true },
    );
    const repo = try tmp.dir.realPathFileAlloc(
        defaultIo(),
        "repo",
        allocator,
    );
    defer allocator.free(repo);
    try std.testing.expectError(
        error.SymlinkComponent,
        RecoveryPaths.init(allocator, repo, "dtx-42"),
    );
}

test "common parser accepts named inputs and parameters only on artifact commands" {
    var args = try parseCommonArgs(std.testing.allocator, &.{
        "--definition",
        "artifact.json",
        "--input",
        "record=input.json",
        "--param",
        "id=one",
        "--format",
        "json",
    }, true);
    defer args.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), args.input_specs.len);
    try std.testing.expectEqual(@as(usize, 1), args.parameter_specs.len);
}

test "command parsers reject duplicate singleton format options" {
    try std.testing.expectError(
        error.DuplicateFormatOption,
        parseCommonArgs(std.testing.allocator, &.{
            "--definition",
            "artifact.json",
            "--format",
            "json",
            "--format",
            "text",
        }, false),
    );
}

test "table renderers escape terminal control codepoints" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "\"prefix\\u001bmiddle\\u0085suffix\\npipe|\"",
        .{},
    );
    defer parsed.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeProjectionTable(
        std.testing.allocator,
        &output,
        parsed.value,
        true,
        4096,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "\\u001b") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "\\u0085") != null,
    );
    try std.testing.expect(
        std.mem.indexOfScalar(u8, output.written(), 0x1b) == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "\xc2\x85") == null,
    );
}
