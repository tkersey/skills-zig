const std = @import("std");
const builtin = @import("builtin");
const app_meta = @import("app_meta");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const ledger = @import("ledger_v1_core");

const Version = std.mem.trim(u8, app_meta.version, " \t\r\n");
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
    \\commands:
    \\  definition check
    \\  definition describe
    \\  validate
    \\  materialize
    \\  transact
    \\  project
    \\  doctor
    \\  capabilities
    \\  version
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
    format: Format,
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
        std.mem.eql(u8, argv[1], "doctor");
}

pub fn runWithArgv(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    if (argv.len < 2 or isHelp(argv[1])) {
        try writeStdout(Help);
        return 0;
    }
    if (std.mem.eql(u8, argv[1], "version") or isVersion(argv[1])) {
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        try stdout_writer.interface.print("{s}\n", .{Version});
        return 0;
    }
    if (std.mem.eql(u8, argv[1], "capabilities")) {
        return emitCapabilities(argv[2..]);
    }
    if (std.mem.eql(u8, argv[1], "definition")) {
        if (argv.len < 3) return error.MissingDefinitionAction;
        if (std.mem.eql(u8, argv[2], "check")) {
            return runDefinitionCheck(allocator, environment, argv[3..]);
        }
        if (std.mem.eql(u8, argv[2], "describe")) {
            return runDefinitionDescribe(allocator, environment, argv[3..]);
        }
        return error.UnknownDefinitionAction;
    }
    if (std.mem.eql(u8, argv[1], "validate")) {
        return runValidate(allocator, environment, argv[2..]);
    }
    if (std.mem.eql(u8, argv[1], "materialize")) {
        return runMaterialize(allocator, environment, argv[2..]);
    }
    if (std.mem.eql(u8, argv[1], "transact")) {
        return runTransact(allocator, environment, argv[2..]);
    }
    if (std.mem.eql(u8, argv[1], "project")) {
        return runProject(allocator, environment, argv[2..]);
    }
    if (std.mem.eql(u8, argv[1], "doctor")) {
        return runDoctor(allocator, environment, argv[2..]);
    }
    return error.UnknownCommand;
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
    var context = try loadDefinition(
        allocator,
        environment,
        args.definition_path,
        .{ .kind = .definition_check },
    );
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
    var format: Format = .json;
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
            format = try Format.parse(argv[index]);
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

fn loadDefinition(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    path: []const u8,
    route: ledger.compiled_plan.Route,
) !DefinitionContext {
    const absolute = try absoluteDefinitionPathAlloc(allocator, path);
    defer allocator.free(absolute);
    const package_location =
        try definition_core.closure.admittedPackageLocation(absolute);
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
        try definition_core.closure.admittedLocation(absolute, cwd.?);
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
    switch (format) {
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
    }
}

fn emitMaterialization(
    allocator: std.mem.Allocator,
    format: Format,
    result: *const ledger.materialization.Result,
    compile_stats: definition_core.result.CompileStats,
) !void {
    switch (format) {
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
    }
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
    format: Format,
    payload_only: bool,
    result: *const ledger.projection.Result,
    compile_stats: definition_core.result.CompileStats,
) !void {
    if (payload_only) {
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        try stdout_writer.interface.writeAll(result.payload);
        try stdout_writer.interface.writeByte('\n');
        return;
    }
    switch (format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try ledger.envelope.writeProjectionJson(
                &output.writer,
                result,
                compile_stats,
            );
            try output.writer.writeByte('\n');
            try writeStdout(output.written());
        },
        .text => {
            var stdout_writer =
                std.Io.File.stdout().writer(defaultIo(), &.{});
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                result.payload,
                .{ .duplicate_field_behavior = .@"error" },
            ) catch {
                try stdout_writer.interface.writeAll(result.payload);
                try stdout_writer.interface.writeByte('\n');
                return;
            };
            defer parsed.deinit();
            if (parsed.value == .string) {
                try stdout_writer.interface.writeAll(parsed.value.string);
            } else {
                try stdout_writer.interface.writeAll(result.payload);
            }
            try stdout_writer.interface.writeByte('\n');
        },
    }
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

fn emitCapabilities(argv: []const []const u8) !u8 {
    var format: Format = .json;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        if (!std.mem.eql(u8, argv[index], "--format")) return error.UnknownOption;
        index += 1;
        if (index >= argv.len) return error.MissingOptionValue;
        format = try Format.parse(argv[index]);
    }
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    if (format == .text) {
        try stdout_writer.interface.print(
            "Ledger {s}\nABI: {s}\n",
            .{ Version, ledger.definition.abi },
        );
        return 0;
    }
    try stdout_writer.interface.print(
        "{{\"schema\":\"ledger-capabilities/v1\",\"version\":\"{s}\"," ++
            "\"artifact_abis\":[\"{s}\"],\"operators\":[",
        .{ Version, ledger.definition.abi },
    );
    var first = true;
    for (std.enums.values(ledger.definition.Operator)) |operator| {
        if (!operator.supported()) continue;
        if (!first) try stdout_writer.interface.writeByte(',');
        first = false;
        try stdout_writer.interface.writeAll("{\"id\":");
        try definition_core.canonical_json.writeCanonicalString(
            &stdout_writer.interface,
            operator.id(),
        );
        try stdout_writer.interface.print(
            ",\"version\":{d}}}",
            .{operator.version()},
        );
    }
    try stdout_writer.interface.writeAll(
        "],\"codecs\":[\"json\",\"jsonl\",\"text\"]," ++
            "\"storage_adapters\":[\"pure\",\"addressed-document\",\"event-log\"]," ++
            "\"cache_format\":",
    );
    try stdout_writer.interface.print(
        "{d}",
        .{definition_core.cache.format_version},
    );
    try stdout_writer.interface.writeAll(
        ",\"result_schemas\":[\"ledger-validation-result/v1\"," ++
            "\"ledger-materialization-result/v1\"," ++
            "\"ledger-transaction-result/v1\"," ++
            "\"ledger-projection-result/v1\"]}\n",
    );
    return 0;
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
