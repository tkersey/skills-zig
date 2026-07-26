const std = @import("std");
const app_meta = @import("app_meta");
const definition_core = @import("definition_core");
const ledger = @import("ledger_v1_core");

const Version = std.mem.trim(u8, app_meta.version, " \t\r\n");
threadlocal var runtime_io: ?std.Io = null;

const Help =
    \\ledger
    \\
    \\Passive artifact-definition validation, materialization, transactions, replay, and projections.
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
    \\Definitions are passive JSON. Ledger never executes hooks, grants semantic authority, or inspects session history.
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

const DefinitionContext = struct {
    closure: definition_core.Closure,
    plan: ledger.definition.Plan,

    fn deinit(self: *DefinitionContext, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
        self.closure.deinit(allocator);
        self.* = undefined;
    }
};

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
    const code = runWithArgv(init.gpa, argv) catch |err| blk: {
        emitCommandError(err) catch |write_err| {
            if (isClosedPipe(write_err)) return;
            return write_err;
        };
        break :blk @as(u8, 2);
    };
    if (code != 0) std.process.exit(code);
}

pub fn runWithArgv(
    allocator: std.mem.Allocator,
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
            return runDefinitionCheck(allocator, argv[3..]);
        }
        if (std.mem.eql(u8, argv[2], "describe")) {
            return runDefinitionDescribe(allocator, argv[3..]);
        }
        return error.UnknownDefinitionAction;
    }
    if (std.mem.eql(u8, argv[1], "validate")) {
        return runValidate(allocator, argv[2..]);
    }
    if (std.mem.eql(u8, argv[1], "materialize")) {
        return runMaterialize(allocator, argv[2..]);
    }
    if (std.mem.eql(u8, argv[1], "transact") or
        std.mem.eql(u8, argv[1], "project") or
        std.mem.eql(u8, argv[1], "doctor"))
    {
        return error.CommandKernelNotImplemented;
    }
    return error.UnknownCommand;
}

fn runDefinitionCheck(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !u8 {
    var args = try parseCommonArgs(allocator, argv, false);
    defer args.deinit(allocator);
    var context = try loadDefinition(allocator, args.definition_path);
    defer context.deinit(allocator);
    var validation_plan = try ledger.validation.compile(allocator, &context.plan);
    defer validation_plan.deinit(allocator);
    var materialization_plan = try ledger.materialization.compile(
        allocator,
        &context.plan,
    );
    defer materialization_plan.deinit(allocator);
    switch (args.format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try output.writer.writeAll(
                "{\"schema\":\"ledger-definition-check-result/v1\",\"definition\":{\"id\":",
            );
            try definition_core.canonical_json.writeCanonicalString(
                &output.writer,
                context.plan.id,
            );
            try output.writer.writeAll(",\"digest\":");
            try definition_core.canonical_json.writeCanonicalString(
                &output.writer,
                context.plan.closure_digest[0..],
            );
            try output.writer.writeAll(",\"abi\":\"");
            try output.writer.writeAll(ledger.definition.abi);
            try output.writer.writeAll(
                "\"},\"valid\":true,\"errors\":[],\"passive\":true,\"authority_granted\":false}\n",
            );
            try writeStdout(output.written());
        },
        .text => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print(
                "structurally valid definition {s}@{s}\n",
                .{ context.plan.id, context.plan.closure_digest[0..] },
            );
        },
    }
    return 0;
}

fn runDefinitionDescribe(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !u8 {
    var args = try parseCommonArgs(allocator, argv, false);
    defer args.deinit(allocator);
    var context = try loadDefinition(allocator, args.definition_path);
    defer context.deinit(allocator);
    switch (args.format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try ledger.envelope.writeDefinitionDescriptionJson(
                &output.writer,
                &context.plan,
            );
            try output.writer.writeByte('\n');
            try writeStdout(output.written());
        },
        .text => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print(
                "{s}\nowner: {s}\ndigest: {s}\nabi: {s}\n",
                .{
                    context.plan.id,
                    context.plan.owner,
                    context.plan.closure_digest[0..],
                    ledger.definition.abi,
                },
            );
        },
    }
    return 0;
}

fn runValidate(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !u8 {
    var args = try parseCommonArgs(allocator, argv, true);
    defer args.deinit(allocator);
    var context = try loadDefinition(allocator, args.definition_path);
    defer context.deinit(allocator);
    var bindings = try bindParameters(
        allocator,
        &context.plan.parameter_declarations,
        args.parameter_specs,
    );
    defer bindings.deinit(allocator);
    var validation_plan = try ledger.validation.compile(allocator, &context.plan);
    defer validation_plan.deinit(allocator);
    const owned_documents = try readDocuments(
        allocator,
        &validation_plan,
        args.input_specs,
    );
    defer deinitDocuments(allocator, owned_documents);
    const documents = try documentViews(allocator, owned_documents);
    defer allocator.free(documents);
    var result = try ledger.validation.validate(
        allocator,
        &context.plan,
        &validation_plan,
        documents,
    );
    defer result.deinit(allocator);
    try emitValidation(allocator, args.format, &result);
    return if (result.valid) 0 else 2;
}

fn runMaterialize(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !u8 {
    var args = try parseCommonArgs(allocator, argv, true);
    defer args.deinit(allocator);
    var context = try loadDefinition(allocator, args.definition_path);
    defer context.deinit(allocator);
    var bindings = try bindParameters(
        allocator,
        &context.plan.parameter_declarations,
        args.parameter_specs,
    );
    defer bindings.deinit(allocator);
    var validation_plan = try ledger.validation.compile(allocator, &context.plan);
    defer validation_plan.deinit(allocator);
    var materialization_plan = try ledger.materialization.compile(
        allocator,
        &context.plan,
    );
    defer materialization_plan.deinit(allocator);
    const owned_documents = try readDocuments(
        allocator,
        &validation_plan,
        args.input_specs,
    );
    defer deinitDocuments(allocator, owned_documents);
    const documents = try documentViews(allocator, owned_documents);
    defer allocator.free(documents);
    var result = try ledger.materialization.materialize(
        allocator,
        &context.plan,
        &validation_plan,
        &materialization_plan,
        documents,
    );
    defer result.deinit(allocator);
    try emitMaterialization(allocator, args.format, &result);
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

fn loadDefinition(
    allocator: std.mem.Allocator,
    path: []const u8,
) !DefinitionContext {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(defaultIo(), ".", allocator);
    defer allocator.free(cwd);
    const absolute = try std.fs.path.resolve(allocator, &.{ cwd, path });
    defer allocator.free(absolute);
    const within_cwd = pathWithin(absolute, cwd);
    const root = if (within_cwd)
        cwd
    else
        std.fs.path.dirname(absolute) orelse return error.InvalidDefinitionPath;
    const entry = if (within_cwd)
        relativeWithin(absolute, cwd)
    else
        std.fs.path.basename(absolute);
    var closure = try definition_core.closure.load(
        allocator,
        root,
        entry,
        .{},
    );
    errdefer closure.deinit(allocator);
    const plan = try ledger.definition.compile(allocator, &closure, entry);
    return .{ .closure = closure, .plan = plan };
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
    const inputs = try allocator.alloc(definition_core.parameters.Input, specs.len);
    defer allocator.free(inputs);
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
    return definition_core.parameters.bind(allocator, declarations, inputs);
}

fn emitValidation(
    allocator: std.mem.Allocator,
    format: Format,
    result: *const ledger.validation.Result,
) !void {
    switch (format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try ledger.envelope.writeValidationJson(&output.writer, result);
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
) !void {
    switch (format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try ledger.envelope.writeMaterializationJson(&output.writer, result);
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
        "{{\"schema\":\"ledger-capabilities/v1\",\"version\":\"{s}\",\"artifact_abis\":[\"{s}\"],\"operators\":[",
        .{ Version, ledger.definition.abi },
    );
    var first = true;
    inline for (@typeInfo(ledger.definition.Operator).@"enum".fields) |field| {
        const operator: ledger.definition.Operator = @enumFromInt(field.value);
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
    try stdout_writer.interface.print(
        "],\"codecs\":[\"json\",\"jsonl\",\"text\"],\"storage_adapters\":[\"pure\",\"addressed-document\",\"event-log\"],\"cache_format\":{d},\"result_schemas\":[\"ledger-validation-result/v1\",\"ledger-materialization-result/v1\",\"ledger-transaction-result/v1\",\"ledger-projection-result/v1\"]}}\n",
        .{definition_core.cache.format_version},
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

fn pathWithin(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or
        (path.len > root.len and
            std.mem.startsWith(u8, path, root) and
            path[root.len] == std.fs.path.sep);
}

fn relativeWithin(path: []const u8, root: []const u8) []const u8 {
    if (std.mem.eql(u8, path, root)) return "";
    return path[root.len + 1 ..];
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
