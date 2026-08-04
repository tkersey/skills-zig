const std = @import("std");
const app_meta = @import("app_meta");
const definition_core = @import("definition_core");
const seq = @import("seq_v1_core");

const Version = std.mem.trim(u8, app_meta.version, " \t\r\n");
const source_adapter_version = "seq-source-adapter-set/v1";
const max_output_cells: usize = 4_000_000;
const max_discovery_bytes: usize = 256 * 1024 * 1024;
threadlocal var runtime_io: ?std.Io = null;

const Help =
    \\seq
    \\
    \\Provenance-preserving observations over agent execution and session evidence.
    \\
    \\usage: seq <command> [options]
    \\
    \\definition commands:
    \\  seq definition check --definition <file> [--format json|text]
    \\  seq definition describe --definition <file> [--format json|text]
    \\
    \\observation commands:
    \\  seq observe --definition <file> --projection <name>
    \\    [--root <dir>] [--session-id <id> | --path <file>] [--repo <dir>]
    \\    [--since <time>] [--until <time>] [--last <duration>]
    \\    [--input <name>=<file|->]... [--param <name>=<value>]...
    \\    [--format json]
    \\  seq explain --definition <file> --projection <name>
    \\    [--param <name>=<value>]... [--format json|text]
    \\
    \\physical commands:
    \\  sessions
    \\  turns
    \\  session-detail
    \\  tool-lifecycle
    \\  session-graph
    \\  tail
    \\  find-session
    \\  datasets
    \\  dataset-schema
    \\  query
    \\  index
    \\
    \\metadata commands:
    \\  seq capabilities [--format json|text]
    \\  seq version
    \\
    \\Definitions are passive JSON. Seq reports observations and limitations
    \\without granting authority.
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

const DefinitionArgs = struct {
    definition_path: []const u8,
    format: Format,
};

const ObserveArgs = struct {
    definition_path: []const u8,
    projection: []const u8,
    selectors: seq.native.Options,
    input_specs: []const []const u8,
    parameter_specs: []const []const u8,
    format: Format,

    fn deinit(self: *ObserveArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.input_specs);
        allocator.free(self.parameter_specs);
        self.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    runtime_io = init.io;
    defer runtime_io = null;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (isHostSequenceInvocation(argv[1..])) {
        const system_argv = try init.arena.allocator().alloc(
            []const u8,
            argv.len,
        );
        system_argv[0] = "/usr/bin/seq";
        @memcpy(system_argv[1..], argv[1..]);
        return std.process.replace(init.io, .{ .argv = system_argv });
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
    command_name: []const u8,
    argv: []const []const u8,
) !u8 {
    if (std.mem.eql(u8, command_name, "capabilities")) {
        if (isOnlyHelp(argv)) {
            try writeStdout(Help);
            return 0;
        }
        return emitCapabilities(argv);
    }
    if (std.mem.eql(u8, command_name, "definition")) {
        return runDefinitionCommand(allocator, environment, argv);
    }
    if (std.mem.eql(u8, command_name, "observe")) {
        if (isOnlyHelp(argv)) {
            try writeStdout(Help);
            return 0;
        }
        return runObserve(allocator, environment, argv);
    }
    if (std.mem.eql(u8, command_name, "explain")) {
        if (isOnlyHelp(argv)) {
            try writeStdout(Help);
            return 0;
        }
        return runExplain(allocator, environment, argv);
    }
    if (seq.native.Command.parse(command_name)) |command| {
        if (isOnlyHelp(argv)) {
            try writeStdout(seq.native.help(command));
            return 0;
        }
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        return seq.native.run(
            allocator,
            environment,
            command,
            argv,
            &stdout_writer.interface,
            defaultIo(),
        );
    }
    return error.UnknownCommand;
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

fn runExplain(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    var args = try parseObserveArgs(allocator, argv);
    defer args.deinit(allocator);
    args.selectors.environment = environment;
    const normalized_repo = if (args.selectors.repo) |repo|
        try seq.native.absolutePathAlloc(allocator, environment, repo)
    else
        null;
    defer if (normalized_repo) |repo| allocator.free(repo);
    if (normalized_repo) |repo| args.selectors.repo = repo;
    if (hasPhysicalSelector(args.selectors) or args.input_specs.len != 0) {
        return error.ExplainDoesNotReadCorpus;
    }
    const projection_names = [_][]const u8{args.projection};
    var context = try loadDefinition(
        allocator,
        environment,
        args.definition_path,
        .{ .projection_names = &projection_names },
    );
    defer context.deinit(allocator);
    var bindings = try bindParameters(
        allocator,
        &context.definition_plan.parameter_declarations,
        args.parameter_specs,
    );
    defer bindings.deinit(allocator);
    if (usesRelationGraph(&context.definition_plan)) {
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        try writeGraphExplanation(
            allocator,
            &stdout_writer.interface,
            &context,
            &args,
        );
        return 0;
    }
    var program = try seq.execution.compile(
        allocator,
        &context.definition_plan,
        &context.native_plan,
        &bindings,
        args.projection,
    );
    defer program.deinit(allocator);

    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    if (args.format == .text) {
        try writeExplanationText(
            &stdout_writer.interface,
            &context,
            &args,
            &program,
        );
        return 0;
    }
    try writeExplanationJson(
        &stdout_writer.interface,
        &context,
        &args,
        &program,
    );
    return 0;
}

fn writeGraphExplanation(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    context: *const seq.compiled_plan.PlanSet,
    args: *const ObserveArgs,
) !void {
    const scans = try seq.relation_graph.requiredScanStages(
        allocator,
        &context.definition_plan,
        &context.native_plan,
        args.projection,
    );
    defer allocator.free(scans);
    const streaming = try seq.relation_graph.streamingLineagePlan(
        allocator,
        &context.definition_plan,
        &context.native_plan,
        args.projection,
    );
    if (args.format == .text) {
        try writer.print(
            "{s}@{s}\nprojection: {s}\nsources: {d}\nstages: {d}\nmax_rows: {d}\n",
            .{
                context.definition_plan.id,
                context.definition_plan.closure_digest[0..],
                args.projection,
                scans.len,
                context.native_plan.stages.len,
                context.definition_plan.bounds.max_rows,
            },
        );
        if (streaming) |schedule| {
            try writer.print(
                "strategy: partition-lineage-stream\npartition_relation: {s}\nretained_byte_bound: {d}\n",
                .{
                    @tagName(context.native_plan.stages[schedule.scan_stage].operation.scan.relation),
                    streaming_retained_byte_bound,
                },
            );
        } else {
            try writer.writeAll("strategy: materialized-graph\n");
        }
        return;
    }
    try writer.writeAll(
        "{\"schema\":\"seq-observation-plan/v1\",\"definition\":{\"id\":",
    );
    try writeString(writer, context.definition_plan.id);
    try writer.writeAll(",\"digest\":");
    try writeString(writer, &context.definition_plan.closure_digest);
    try writer.writeAll(",\"abi\":\"");
    try writer.writeAll(seq.definition.abi);
    try writer.writeAll("\"},\"projection\":");
    try writeString(writer, args.projection);
    try writer.writeAll(",\"sources\":[");
    for (scans, 0..) |stage_index, index| {
        if (index != 0) try writer.writeByte(',');
        const scan = context.native_plan.stages[stage_index].operation.scan;
        try writer.writeAll("{\"kind\":\"physical\",\"relation\":");
        try writeString(writer, @tagName(scan.relation));
        try writer.writeByte('}');
    }
    try writer.print(
        "],\"stage_count\":{d},\"max_rows\":{d},\"compile_stats\":",
        .{ context.native_plan.stages.len, context.definition_plan.bounds.max_rows },
    );
    try writeCompileStats(writer, context.stats);
    if (streaming) |schedule| {
        try writer.writeAll(",\"strategy\":{\"kind\":\"partition-lineage-stream\",\"partition_relation\":");
        try writeString(
            writer,
            @tagName(context.native_plan.stages[schedule.scan_stage].operation.scan.relation),
        );
        try writer.print(",\"retained_byte_bound\":{d}}}", .{streaming_retained_byte_bound});
    } else {
        try writer.writeAll(",\"strategy\":{\"kind\":\"materialized-graph\"}");
    }
    try writer.writeAll(",\"corpus_read\":false,\"authority_granted\":false}\n");
}

fn usesRelationGraph(definition_plan: *const seq.definition.Plan) bool {
    return definition_plan.requires(.derive) or
        definition_plan.requires(.join) or
        definition_plan.requires(.ordered_fold) or
        definition_plan.requires(.reachability);
}

fn emitGraphObservation(
    allocator: std.mem.Allocator,
    args: *const ObserveArgs,
    context: *const seq.compiled_plan.PlanSet,
    bindings: *const definition_core.parameters.Bindings,
) !u8 {
    const execution_start = monotonicNanoseconds();
    var graph = try executeGraphObservation(
        allocator,
        args,
        context,
        bindings,
    );
    defer graph.deinit(allocator);
    const execution_ns = elapsedNanoseconds(execution_start);
    var execution_stats = definition_core.result.ExecutionStats{
        .execution_ns = execution_ns,
        .physical_passes = 1,
        .files_opened = graph.files_opened,
        .bytes_read = graph.bytes_read,
        .rows_scanned = graph.result.source_row_count,
        .rows_materialized = graph.result.materialized_row_count,
        .output_rows = graph.result.row_count,
    };
    const rendered = try renderObservationAlloc(
        allocator,
        .{
            .definition_plan = &context.definition_plan,
            .projection_name = args.projection,
            .parameters_digest = &bindings.values_digest,
            .corpus = .{
                .adapter = graph.corpus_adapter,
                .digest = &graph.corpus_digest,
                .files = graph.corpus_files,
                .sessions = graph.corpus_sessions,
                .contaminated = graph.warning_count != 0,
            },
            .rows = graph.result.rows(),
            .compile_stats = context.stats,
            .execution_stats = execution_stats,
            .limitations = observationLimitations(
                graph.warning_count,
                false,
            ),
        },
        &execution_stats,
    );
    defer allocator.free(rendered);
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(rendered);
    try stdout_writer.interface.writeByte('\n');
    return 0;
}

fn writeExplanationText(
    writer: *std.Io.Writer,
    context: *const seq.compiled_plan.PlanSet,
    args: *const ObserveArgs,
    program: *const seq.execution.Program,
) !void {
    try writer.print(
        "{s}@{s}\nprojection: {s}\nsource: {s}\nfields: {d}\nmax_rows: {d}\n",
        .{
            context.definition_plan.id,
            context.definition_plan.closure_digest[0..],
            args.projection,
            explanationSourceName(context, program),
            program.source_field_indices.len,
            program.max_rows,
        },
    );
}

fn explanationSourceName(
    context: *const seq.compiled_plan.PlanSet,
    program: *const seq.execution.Program,
) []const u8 {
    return switch (program.source) {
        .physical => |relation| @tagName(relation),
        .external => |index| context.definition_plan.inputs[index].name,
    };
}

fn writeExplanationJson(
    writer: *std.Io.Writer,
    context: *const seq.compiled_plan.PlanSet,
    args: *const ObserveArgs,
    program: *const seq.execution.Program,
) !void {
    try writer.writeAll(
        "{\"schema\":\"seq-observation-plan/v1\",\"definition\":{\"id\":",
    );
    try writeString(writer, context.definition_plan.id);
    try writer.writeAll(",\"digest\":");
    try writeString(
        writer,
        &context.definition_plan.closure_digest,
    );
    try writer.writeAll(",\"abi\":\"");
    try writer.writeAll(seq.definition.abi);
    try writer.writeAll("\"},\"projection\":");
    try writeString(writer, args.projection);
    try writer.writeAll(",\"source\":{\"kind\":");
    switch (program.source) {
        .physical => |relation| {
            try writer.writeAll("\"physical\",\"relation\":");
            try writeString(writer, @tagName(relation));
        },
        .external => |index| {
            try writer.writeAll("\"external\",\"input\":");
            try writeString(writer, context.definition_plan.inputs[index].name);
        },
    }
    try writer.writeAll("},\"required_fields\":[");
    try writeExplanationFields(writer, context, program);
    try writer.print(
        "],\"source_width\":{d},\"output_width\":{d}," ++
            "\"max_rows\":{d},\"compile_stats\":",
        .{
            program.source_width,
            program.output_field_indices.len,
            program.max_rows,
        },
    );
    try writeCompileStats(writer, context.stats);
    try writer.writeAll(
        ",\"corpus_read\":false,\"authority_granted\":false}\n",
    );
}

fn writeExplanationFields(
    writer: *std.Io.Writer,
    context: *const seq.compiled_plan.PlanSet,
    program: *const seq.execution.Program,
) !void {
    switch (program.source) {
        .physical => |relation| {
            for (program.source_field_indices, 0..) |field_index, index| {
                if (index != 0) try writer.writeByte(',');
                try writeString(writer, relation.fields()[field_index].name);
            }
        },
        .external => |input_index| {
            const fields = context.definition_plan.inputs[input_index].fields;
            for (program.source_field_indices, 0..) |field_index, index| {
                if (index != 0) try writer.writeByte(',');
                try writeString(writer, fields[field_index].name);
            }
        },
    }
}

fn runDefinitionCheck(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    const args = try parseDefinitionArgs(argv);
    var context = loadDefinition(
        allocator,
        environment,
        args.definition_path,
        .{},
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
                "{\"schema\":\"seq-definition-check-result/v1\",\"definition\":{\"id\":",
            );
            try writeString(&output.writer, context.definition_plan.id);
            try output.writer.writeAll(",\"digest\":");
            try writeString(
                &output.writer,
                &context.definition_plan.closure_digest,
            );
            try output.writer.writeAll(",\"abi\":\"");
            try output.writer.writeAll(seq.definition.abi);
            try output.writer.writeAll(
                "\"},\"valid\":true,\"errors\":[],\"compile_stats\":",
            );
            try writeCompileStats(&output.writer, context.stats);
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
        "{\"schema\":\"seq-definition-check-result/v1\"," ++
            "\"definition\":null,\"valid\":false,\"errors\":[{\"code\":",
    );
    try writeString(&stdout_writer.interface, @errorName(err));
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
    const args = try parseDefinitionArgs(argv);
    var context = try loadDefinition(
        allocator,
        environment,
        args.definition_path,
        .{},
    );
    defer context.deinit(allocator);
    switch (args.format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try writeDefinitionDescriptionJson(&output.writer, &context);
            try writeStdout(output.written());
        },
        .text => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try writeDefinitionDescriptionText(
                &stdout_writer.interface,
                &context,
            );
        },
    }
    return 0;
}

fn writeDefinitionDescriptionJson(
    writer: *std.Io.Writer,
    context: *const seq.compiled_plan.PlanSet,
) !void {
    try writer.writeAll(
        "{\"schema\":\"seq-definition-description/v1\",\"definition\":{\"id\":",
    );
    try writeString(writer, context.definition_plan.id);
    try writer.writeAll(",\"digest\":");
    try writeString(writer, &context.definition_plan.closure_digest);
    try writer.writeAll(",\"abi\":\"");
    try writer.writeAll(seq.definition.abi);
    try writer.writeAll("\"},\"operators\":[");
    var first = true;
    for (std.enums.values(seq.definition.Operator)) |operator| {
        if (!context.definition_plan.requires(operator)) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writeString(writer, operator.id());
    }
    try writer.writeAll("],\"selectors\":[");
    first = true;
    for (std.enums.values(seq.definition.Selector)) |selector| {
        if (!selectorAllowed(&context.definition_plan, selector)) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writeString(writer, selector.id());
    }
    try writer.writeAll("],\"projections\":[");
    for (context.definition_plan.projections, 0..) |projection, index| {
        if (index != 0) try writer.writeByte(',');
        try writeString(writer, projection.name);
    }
    try writer.writeAll("],\"compile_stats\":");
    try writeCompileStats(writer, context.stats);
    try writer.writeAll(
        ",\"passive\":true,\"authority_granted\":false}\n",
    );
}

fn writeDefinitionDescriptionText(
    writer: *std.Io.Writer,
    context: *const seq.compiled_plan.PlanSet,
) !void {
    try writer.print(
        "{s}\ndigest: {s}\nabi: {s}\n",
        .{
            context.definition_plan.id,
            context.definition_plan.closure_digest[0..],
            seq.definition.abi,
        },
    );
}

fn runObserve(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    var args = try parseObserveArgs(allocator, argv);
    defer args.deinit(allocator);
    args.selectors.environment = environment;
    const normalized_repo = if (args.selectors.repo) |repo|
        try seq.native.absolutePathAlloc(allocator, environment, repo)
    else
        null;
    defer if (normalized_repo) |repo| allocator.free(repo);
    if (normalized_repo) |repo| args.selectors.repo = repo;
    if (args.format != .json) return error.UnsupportedObservationRenderer;
    const projection_names = [_][]const u8{args.projection};
    var context = try loadDefinition(
        allocator,
        environment,
        args.definition_path,
        .{ .projection_names = &projection_names },
    );
    defer context.deinit(allocator);
    const projection = findProjection(
        context.definition_plan.projections,
        args.projection,
    ) orelse return error.UnknownObservationProjection;
    const json_renderer_bit = @as(u8, 1) <<
        @intCast(@intFromEnum(seq.definition.Renderer.json));
    if ((projection.renderer_mask & json_renderer_bit) == 0) {
        return error.ObservationRendererNotDeclared;
    }
    var bindings = try bindParameters(
        allocator,
        &context.definition_plan.parameter_declarations,
        args.parameter_specs,
    );
    defer bindings.deinit(allocator);
    if (usesRelationGraph(&context.definition_plan)) {
        return emitGraphObservation(
            allocator,
            &args,
            &context,
            &bindings,
        );
    }
    var program = try seq.execution.compile(
        allocator,
        &context.definition_plan,
        &context.native_plan,
        &bindings,
        args.projection,
    );
    defer program.deinit(allocator);
    return emitObservation(
        allocator,
        &args,
        &context,
        &bindings,
        &program,
    );
}

fn emitObservation(
    allocator: std.mem.Allocator,
    args: *const ObserveArgs,
    context: *const seq.compiled_plan.PlanSet,
    bindings: *const definition_core.parameters.Bindings,
    program: *const seq.execution.Program,
) !u8 {
    const output_width = program.output_field_indices.len;
    const output_cells = std.math.mul(
        usize,
        program.max_rows,
        output_width,
    ) catch return error.ObservationOutputCellBoundExceeded;
    if (output_cells > max_output_cells) {
        return error.ObservationOutputCellBoundExceeded;
    }
    const output = try allocator.alloc(seq.execution.Value, output_cells);
    defer allocator.free(output);
    const execution_start = monotonicNanoseconds();
    var execution = try executeObservation(
        allocator,
        args,
        context,
        program,
        output,
    );
    defer execution.deinit(allocator);
    const execution_ns = elapsedNanoseconds(execution_start);
    var execution_stats = definition_core.result.ExecutionStats{
        .execution_ns = execution_ns,
        .physical_passes = 1,
        .files_opened = execution.files_opened,
        .bytes_read = execution.bytes_read,
        .rows_scanned = execution.result.source_row_count,
        .rows_materialized = execution.result.materialized_row_count,
        .output_rows = execution.result.row_count,
    };
    const rendered = try renderObservationAlloc(
        allocator,
        .{
            .definition_plan = &context.definition_plan,
            .projection_name = args.projection,
            .parameters_digest = &bindings.values_digest,
            .corpus = .{
                .adapter = execution.corpus_adapter,
                .digest = &execution.corpus_digest,
                .files = execution.corpus_files,
                .sessions = execution.corpus_sessions,
                .contaminated = execution.warning_count != 0,
            },
            .rows = execution.result.rows(),
            .compile_stats = context.stats,
            .execution_stats = execution_stats,
            .limitations = observationLimitations(
                execution.warning_count,
                programMayTruncate(program),
            ),
        },
        &execution_stats,
    );
    defer allocator.free(rendered);
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(rendered);
    try stdout_writer.interface.writeByte('\n');
    return 0;
}

const ObservationExecution = struct {
    result: seq.execution.Result,
    runner: ?seq.execution.Runner = null,
    external_relation: ?seq.external_input.Relation = null,
    corpus_adapter: []const u8,
    corpus_digest: [71]u8,
    corpus_files: usize,
    corpus_sessions: usize,
    files_opened: usize,
    bytes_read: usize,
    warning_count: usize = 0,
    graph_arena: ?*std.heap.ArenaAllocator = null,
    graph_result_owned: bool = false,

    fn deinit(self: *ObservationExecution, allocator: std.mem.Allocator) void {
        if (self.runner) |*runner| runner.deinit();
        if (self.external_relation) |*relation| relation.deinit(allocator);
        if (self.graph_arena) |arena| {
            if (self.graph_result_owned) allocator.free(self.result.values);
            arena.deinit();
            allocator.destroy(arena);
        }
        self.* = undefined;
    }
};

const GraphScanRows = struct {
    stage_index: u16,
    relation: seq.physical.Relation,
    field_indices: []const u16,
    values: std.ArrayList(seq.execution.Value) = .empty,
};

fn executeGraphObservation(
    allocator: std.mem.Allocator,
    args: *const ObserveArgs,
    context: *const seq.compiled_plan.PlanSet,
    bindings: *const definition_core.parameters.Bindings,
) !ObservationExecution {
    if (args.input_specs.len != 0) {
        return error.ExternalInputNotAcceptedForPhysicalObservation;
    }
    try validateSelectedSelectors(&context.definition_plan, args.selectors);
    if (try seq.relation_graph.streamingLineagePlan(
        allocator,
        &context.definition_plan,
        &context.native_plan,
        args.projection,
    )) |schedule| {
        return executeStreamingGraphObservation(
            allocator,
            args,
            context,
            bindings,
            schedule,
        );
    }
    const scan_stages = try seq.relation_graph.requiredScanStages(
        allocator,
        &context.definition_plan,
        &context.native_plan,
        args.projection,
    );
    defer allocator.free(scan_stages);
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();
    const graph_allocator = arena.allocator();
    const table_allocator = std.heap.page_allocator;
    const scan_rows = try allocator.alloc(GraphScanRows, scan_stages.len);
    var initialized_scan_rows: usize = 0;
    defer {
        for (scan_rows[0..initialized_scan_rows]) |*rows| rows.values.deinit(table_allocator);
        allocator.free(scan_rows);
    }
    var relations: std.ArrayList(seq.physical.Relation) = .empty;
    defer relations.deinit(allocator);
    for (scan_stages, 0..) |stage_index, index| {
        const scan = switch (context.native_plan.stages[stage_index].operation) {
            .scan => |value| value,
            else => return error.ObservationPhysicalScanMissing,
        };
        scan_rows[index] = .{
            .stage_index = stage_index,
            .relation = scan.relation,
            .field_indices = scan.field_indices,
        };
        initialized_scan_rows += 1;
        var seen = false;
        for (relations.items) |relation| if (relation == scan.relation) {
            seen = true;
            break;
        };
        if (!seen) try relations.append(allocator, scan.relation);
    }
    var discovery_selectors = args.selectors;
    discovery_selectors.path = null;
    discovery_selectors.session_id = null;
    discovery_selectors.since_ms = null;
    discovery_selectors.until_ms = null;
    var paths = try seq.native.resolveTargetPaths(
        allocator,
        defaultIo(),
        discovery_selectors,
        false,
    );
    defer seq.native.freePaths(allocator, &paths);
    for (scan_rows) |*rows| {
        const capacity_rows = if (rows.relation == .token_events)
            context.definition_plan.bounds.max_rows
        else
            paths.items.len;
        try rows.values.ensureTotalCapacity(
            table_allocator,
            try std.math.mul(usize, capacity_rows, rows.field_indices.len),
        );
    }
    var metrics = PhysicalMetrics{};
    var digest_set = CorpusSetHasher{};
    var value_interner = seq.trace_adapter.ValueInterner{};
    defer value_interner.deinit(table_allocator);
    for (paths.items) |path| {
        if (seq.opencode_adapter.recognizes(path)) {
            return error.GraphObservationOpenCodeUnsupported;
        }
        const selected = try seq.trace_adapter.parseRelationsFileSelected(
            allocator,
            relations.items,
            path,
            .{
                .max_input_bytes = if (metrics.corpus_bytes < context.definition_plan.bounds.max_input_bytes)
                    context.definition_plan.bounds.max_input_bytes - metrics.corpus_bytes
                else
                    0,
            },
            .{
                .repo = args.selectors.repo,
            },
        );
        if (selected.file_opened) metrics.opened += 1;
        try recordDiscoveryBytes(&metrics, selected.discovery_bytes_read);
        var parsed = selected.parsed orelse continue;
        defer parsed.deinit(allocator);
        try metrics.admitAdapter("codex-rollout-jsonl/v1");
        try recordCorpusBytes(&metrics, parsed.metrics.bytes_read);
        try admitCodexSession(&metrics, &parsed);
        digest_set.add(path, &parsed.corpus_digest);
        for (scan_rows) |*rows| {
            _ = try seq.trace_adapter.appendRelationRowsAlloc(
                table_allocator,
                graph_allocator,
                &value_interner,
                &rows.values,
                &parsed.trace,
                rows.relation,
                rows.field_indices,
                .{},
            );
        }
    }
    const scans = try allocator.alloc(
        seq.relation_graph.ScanInput,
        scan_rows.len,
    );
    var initialized_scans: usize = 0;
    defer {
        for (scans[0..initialized_scans]) |scan| {
            if (scan.owned) table_allocator.free(scan.allocation orelse scan.table.values);
        }
        allocator.free(scans);
    }
    for (scan_rows, 0..) |*rows, index| {
        const values = rows.values.items;
        const allocation = values.ptr[0..rows.values.capacity];
        rows.values = .empty;
        scans[index] = .{
            .stage_index = rows.stage_index,
            .table = .{
                .values = values,
                .width = rows.field_indices.len,
            },
            .allocation = allocation,
            .owned = true,
        };
        initialized_scans += 1;
    }
    const graph_result = try seq.relation_graph.execute(
        table_allocator,
        graph_allocator,
        &context.definition_plan,
        &context.native_plan,
        bindings,
        .{
            .path = args.selectors.path,
            .root = args.selectors.root,
            .session_id = args.selectors.session_id,
            .repo = args.selectors.repo,
            .since_ms = args.selectors.since_ms,
            .until_ms = args.selectors.until_ms,
        },
        args.projection,
        scans,
    );
    const retained_result_values = try graph_allocator.dupe(
        seq.execution.Value,
        graph_result.table.values,
    );
    table_allocator.free(graph_result.table.values);
    return .{
        .result = .{
            .values = retained_result_values,
            .width = graph_result.table.width,
            .row_count = try graph_result.table.rowCount(),
            .source_row_count = graph_result.source_rows,
            .materialized_row_count = graph_result.materialized_rows,
        },
        .corpus_adapter = metrics.adapter orelse "codex-rollout-jsonl/v1",
        .corpus_digest = digest_set.digest(),
        .corpus_files = metrics.files,
        .corpus_sessions = metrics.sessions,
        .files_opened = metrics.opened,
        .bytes_read = metrics.bytes_read,
        .warning_count = metrics.warnings,
        .graph_arena = arena,
    };
}

const DiscoveredSession = struct {
    path_index: usize,
    identity: seq.trace_adapter.SessionIdentity,
    depth: usize = 0,
    visiting: bool = false,
    resolved: bool = false,
};

const StreamingParseTask = struct {
    path: []const u8,
    relation: seq.physical.Relation,
    max_input_bytes: usize,
    repo: ?[]const u8,
    selected: ?seq.trace_adapter.SelectedParse = null,
    failure: ?anyerror = null,

    fn run(self: *StreamingParseTask) void {
        self.selected = seq.trace_adapter.parseRelationsFileSelected(
            std.heap.smp_allocator,
            &.{self.relation},
            self.path,
            .{ .max_input_bytes = self.max_input_bytes },
            .{ .repo = self.repo },
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const streaming_retained_byte_bound: usize = 1536 * 1024 * 1024;

fn executeStreamingGraphObservation(
    allocator: std.mem.Allocator,
    args: *const ObserveArgs,
    context: *const seq.compiled_plan.PlanSet,
    bindings: *const definition_core.parameters.Bindings,
    schedule: seq.relation_graph.StreamingLineagePlan,
) !ObservationExecution {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();
    const graph_allocator = arena.allocator();
    const table_allocator = std.heap.page_allocator;

    var discovery_selectors = args.selectors;
    discovery_selectors.path = null;
    discovery_selectors.session_id = null;
    discovery_selectors.since_ms = null;
    discovery_selectors.until_ms = null;
    var paths = try seq.native.resolveTargetPaths(
        allocator,
        defaultIo(),
        discovery_selectors,
        false,
    );
    defer seq.native.freePaths(allocator, &paths);

    const discovered = try allocator.alloc(DiscoveredSession, paths.items.len);
    var discovered_count: usize = 0;
    defer {
        for (discovered[0..discovered_count]) |*item| item.identity.deinit(allocator);
        allocator.free(discovered);
    }
    var identity_bytes: usize = 0;
    var session_indices = std.StringHashMap(usize).init(allocator);
    defer session_indices.deinit();
    for (paths.items, 0..) |path, index| {
        discovered[index] = .{
            .path_index = index,
            .identity = try seq.trace_adapter.discoverSessionIdentity(
                allocator,
                path,
                .{},
            ),
        };
        discovered_count += 1;
        identity_bytes = try std.math.add(
            usize,
            identity_bytes,
            discovered[index].identity.bytes_read,
        );
        if (discovered[index].identity.session_id) |session_id| {
            const entry = try session_indices.getOrPut(session_id);
            if (entry.found_existing) return error.DuplicateObservationLineageNode;
            entry.value_ptr.* = index;
        }
    }
    for (discovered, 0..) |_, index| {
        _ = try resolveSessionDepth(
            discovered,
            &session_indices,
            index,
            context.definition_plan.bounds.max_graph_depth,
        );
    }
    std.mem.sort(DiscoveredSession, discovered, {}, discoveredSessionLessThan);
    session_indices.clearRetainingCapacity();
    for (discovered, 0..) |item, index| {
        if (item.identity.session_id) |session_id| {
            try session_indices.put(session_id, index);
        }
    }

    const session_scan = context.native_plan.stages[schedule.graph_stage];
    _ = session_scan;
    const raw_session_stage = try findPartitionScanRoot(
        &context.definition_plan,
        &context.native_plan,
        schedule.graph_stage,
        .sessions,
        0,
    );
    const raw_session_scan = context.native_plan.stages[raw_session_stage].operation.scan;
    var session_values: std.ArrayList(seq.execution.Value) = .empty;
    defer session_values.deinit(table_allocator);
    try session_values.ensureTotalCapacity(
        table_allocator,
        try std.math.mul(usize, discovered.len, raw_session_scan.field_indices.len),
    );
    for (discovered) |item| {
        try appendDiscoveredSession(
            table_allocator,
            graph_allocator,
            &session_values,
            raw_session_scan.field_indices,
            paths.items[item.path_index],
            item.identity,
        );
    }
    const session_seed_values = session_values.items;
    const session_seed_allocation = session_seed_values.ptr[0..session_values.capacity];
    session_values = .empty;
    errdefer table_allocator.free(session_seed_allocation);

    const graph_seed_copy = try table_allocator.dupe(
        seq.execution.Value,
        session_seed_values,
    );
    var graph_seed = [_]seq.relation_graph.ScanInput{.{
        .stage_index = raw_session_stage,
        .table = .{
            .values = graph_seed_copy,
            .width = raw_session_scan.field_indices.len,
        },
        .allocation = graph_seed_copy,
        .owned = true,
    }};
    const lineage_graph = try seq.relation_graph.executeTarget(
        table_allocator,
        graph_allocator,
        &context.definition_plan,
        &context.native_plan,
        bindings,
        graphRuntimeSelectors(args),
        schedule.graph_stage,
        &graph_seed,
    );
    defer table_allocator.free(lineage_graph.table.values);

    var reducer = try seq.relation_graph.StreamingLineageReducer.init(
        table_allocator,
        &context.definition_plan,
        &context.native_plan,
        schedule,
        lineage_graph.table,
        streaming_retained_byte_bound,
    );
    defer reducer.deinit();

    const local_scan = context.native_plan.stages[schedule.scan_stage].operation.scan;
    var metrics = PhysicalMetrics{};
    var digest_set = CorpusSetHasher{};
    var value_interner = seq.trace_adapter.ValueInterner{};
    defer value_interner.deinit(table_allocator);
    var raw_source_rows: usize = 0;
    var materialized_rows: usize = lineage_graph.materialized_rows;
    var included: std.ArrayList(usize) = .empty;
    defer included.deinit(allocator);
    for (discovered, 0..) |item, discovered_index| {
        if (!sessionInSelectionClosure(
            discovered,
            &session_indices,
            discovered_index,
            args.selectors.session_id,
            args.selectors.path,
            paths.items,
            context.definition_plan.bounds.max_graph_depth,
        )) continue;
        const path = paths.items[item.path_index];
        if (seq.opencode_adapter.recognizes(path)) {
            return error.GraphObservationOpenCodeUnsupported;
        }
        try included.append(allocator, discovered_index);
    }
    const parse_tasks = try allocator.alloc(StreamingParseTask, included.items.len);
    defer allocator.free(parse_tasks);
    for (included.items, 0..) |discovered_index, index| {
        parse_tasks[index] = .{
            .path = paths.items[discovered[discovered_index].path_index],
            .relation = local_scan.relation,
            .max_input_bytes = context.definition_plan.bounds.max_input_bytes,
            .repo = args.selectors.repo,
        };
    }
    if (parse_tasks.len != 0) {
        const prefetch = 3;
        var threads = [_]?std.Thread{null} ** prefetch;
        defer for (&threads) |*thread| if (thread.*) |running| running.join();
        for (0..@min(prefetch, parse_tasks.len)) |index| {
            threads[index] = try std.Thread.spawn(
                .{},
                StreamingParseTask.run,
                .{&parse_tasks[index]},
            );
        }
        var task_index: usize = 0;
        while (task_index < parse_tasks.len) : (task_index += 1) {
            const slot = task_index % prefetch;
            const running = threads[slot] orelse unreachable;
            running.join();
            threads[slot] = null;
            if (parse_tasks[task_index].failure) |failure| return failure;
            const next_index = task_index + prefetch;
            if (next_index < parse_tasks.len) {
                threads[slot] = try std.Thread.spawn(
                    .{},
                    StreamingParseTask.run,
                    .{&parse_tasks[next_index]},
                );
            }

            const selected = parse_tasks[task_index].selected orelse
                return error.ObservationPhysicalParseMissing;
            parse_tasks[task_index].selected = null;
            if (selected.file_opened) metrics.opened += 1;
            try recordDiscoveryBytes(&metrics, selected.discovery_bytes_read);
            if (selected.parsed) |value| {
                var parsed = value;
                defer parsed.deinit(std.heap.smp_allocator);
                try metrics.admitAdapter("codex-rollout-jsonl/v1");
                try recordCorpusBytes(&metrics, parsed.metrics.bytes_read);
                try admitCodexSession(&metrics, &parsed);
                digest_set.add(parse_tasks[task_index].path, &parsed.corpus_digest);

                var raw_values: std.ArrayList(seq.execution.Value) = .empty;
                defer raw_values.deinit(table_allocator);
                const appended = try seq.trace_adapter.appendRelationRowsAlloc(
                    table_allocator,
                    graph_allocator,
                    &value_interner,
                    &raw_values,
                    &parsed.trace,
                    local_scan.relation,
                    local_scan.field_indices,
                    .{},
                );
                raw_source_rows = try std.math.add(usize, raw_source_rows, appended);
                const values = raw_values.items;
                const allocation = values.ptr[0..raw_values.capacity];
                raw_values = .empty;
                var local_seed = [_]seq.relation_graph.ScanInput{.{
                    .stage_index = schedule.scan_stage,
                    .table = .{ .values = values, .width = local_scan.field_indices.len },
                    .allocation = allocation,
                    .owned = true,
                }};
                const local = try seq.relation_graph.executeTarget(
                    table_allocator,
                    graph_allocator,
                    &context.definition_plan,
                    &context.native_plan,
                    bindings,
                    graphRuntimeSelectors(args),
                    schedule.local_stage,
                    &local_seed,
                );
                defer table_allocator.free(local.table.values);
                materialized_rows = try std.math.add(
                    usize,
                    materialized_rows,
                    local.materialized_rows,
                );
                try reducer.appendPartition(local.table);
            }
        }
    }
    var owned = try reducer.finish();
    errdefer table_allocator.free(owned.values);

    var final_scans = [_]seq.relation_graph.ScanInput{
        .{
            .stage_index = raw_session_stage,
            .table = .{
                .values = session_seed_values,
                .width = raw_session_scan.field_indices.len,
            },
            .allocation = session_seed_allocation,
            .owned = true,
        },
        .{
            .stage_index = schedule.lineage_stage,
            .table = owned,
            .allocation = owned.values,
            .owned = true,
        },
    };
    owned.values = &.{};
    const graph_result = try seq.relation_graph.execute(
        table_allocator,
        graph_allocator,
        &context.definition_plan,
        &context.native_plan,
        bindings,
        graphRuntimeSelectors(args),
        args.projection,
        &final_scans,
    );
    const retained_result_values = try graph_allocator.dupe(
        seq.execution.Value,
        graph_result.table.values,
    );
    table_allocator.free(graph_result.table.values);
    return .{
        .result = .{
            .values = retained_result_values,
            .width = graph_result.table.width,
            .row_count = try graph_result.table.rowCount(),
            .source_row_count = raw_source_rows,
            .materialized_row_count = try std.math.add(
                usize,
                materialized_rows,
                graph_result.materialized_rows,
            ),
        },
        .corpus_adapter = metrics.adapter orelse "codex-rollout-jsonl/v1",
        .corpus_digest = digest_set.digest(),
        .corpus_files = metrics.files,
        .corpus_sessions = metrics.sessions,
        .files_opened = metrics.opened,
        .bytes_read = try std.math.add(usize, metrics.bytes_read, identity_bytes),
        .warning_count = metrics.warnings,
        .graph_arena = arena,
    };
}

fn sessionInSelectionClosure(
    sessions: []const DiscoveredSession,
    indices: *const std.StringHashMap(usize),
    candidate_index: usize,
    selected_session_id: ?[]const u8,
    selected_path: ?[]const u8,
    paths: []const []const u8,
    max_depth: usize,
) bool {
    if (selected_session_id == null and selected_path == null) return true;
    for (sessions, 0..) |selected, selected_index| {
        const id_matches = if (selected_session_id) |wanted|
            if (selected.identity.session_id) |actual| std.mem.eql(u8, wanted, actual) else false
        else
            false;
        const path_matches = if (selected_path) |wanted|
            std.mem.eql(u8, wanted, paths[selected.path_index])
        else
            false;
        if (!id_matches and !path_matches) continue;
        return lineageRelated(
            sessions,
            indices,
            candidate_index,
            selected_index,
            max_depth,
        ) or lineageRelated(
            sessions,
            indices,
            selected_index,
            candidate_index,
            max_depth,
        );
    }
    return false;
}

fn lineageRelated(
    sessions: []const DiscoveredSession,
    indices: *const std.StringHashMap(usize),
    descendant_index: usize,
    ancestor_index: usize,
    max_depth: usize,
) bool {
    var current = descendant_index;
    var depth: usize = 0;
    while (true) : (depth += 1) {
        if (current == ancestor_index) return true;
        if (depth >= max_depth) return false;
        const parent = sessions[current].identity.parent_session_id orelse return false;
        current = indices.get(parent) orelse return false;
    }
}

fn graphRuntimeSelectors(args: *const ObserveArgs) seq.relation_graph.RuntimeSelectors {
    return .{
        .path = args.selectors.path,
        .root = args.selectors.root,
        .session_id = args.selectors.session_id,
        .repo = args.selectors.repo,
        .since_ms = args.selectors.since_ms,
        .until_ms = args.selectors.until_ms,
    };
}

fn resolveSessionDepth(
    sessions: []DiscoveredSession,
    indices: *const std.StringHashMap(usize),
    index: usize,
    max_depth: usize,
) !usize {
    if (sessions[index].resolved) return sessions[index].depth;
    if (sessions[index].visiting) return error.ObservationGraphCycle;
    sessions[index].visiting = true;
    defer sessions[index].visiting = false;
    const depth = if (sessions[index].identity.parent_session_id) |parent|
        if (indices.get(parent)) |parent_index|
            try std.math.add(
                usize,
                try resolveSessionDepth(sessions, indices, parent_index, max_depth),
                1,
            )
        else
            0
    else
        0;
    if (depth > max_depth) return error.ObservationGraphDepthExceeded;
    sessions[index].depth = depth;
    sessions[index].resolved = true;
    return depth;
}

fn discoveredSessionLessThan(_: void, left: DiscoveredSession, right: DiscoveredSession) bool {
    if (left.depth != right.depth) return left.depth < right.depth;
    return left.path_index < right.path_index;
}

fn appendDiscoveredSession(
    allocator: std.mem.Allocator,
    retained_allocator: std.mem.Allocator,
    output: *std.ArrayList(seq.execution.Value),
    field_indices: []const u16,
    path: []const u8,
    identity: seq.trace_adapter.SessionIdentity,
) !void {
    for (field_indices) |field_index| {
        const field = seq.physical.Relation.sessions.fields()[field_index];
        const value: seq.execution.Value = if (std.mem.eql(u8, field.name, "session_id"))
            if (identity.session_id) |text| .{ .string = try retained_allocator.dupe(u8, text) } else .null
        else if (std.mem.eql(u8, field.name, "parent_session_id"))
            if (identity.parent_session_id) |text| .{ .string = try retained_allocator.dupe(u8, text) } else .null
        else if (std.mem.eql(u8, field.name, "lineage_conflict"))
            .{ .boolean = false }
        else if (std.mem.eql(u8, field.name, "path"))
            .{ .string = try retained_allocator.dupe(u8, path) }
        else if (field.nullable)
            .null
        else
            return error.ObservationSessionDiscoveryFieldUnsupported;
        try output.append(allocator, value);
    }
}

fn findPartitionScanRoot(
    definition_plan: *const seq.definition.Plan,
    native_plan: *const seq.plan.Plan,
    stage_index: u16,
    relation: seq.physical.Relation,
    depth: usize,
) !u16 {
    if (depth > definition_plan.bounds.max_graph_depth) {
        return error.ObservationGraphDepthExceeded;
    }
    const stage = native_plan.stages[stage_index];
    if (stage.operation == .scan) {
        if (stage.operation.scan.relation != relation) {
            return error.ObservationPartitionPrefixHasMultipleScans;
        }
        return stage_index;
    }
    for (definition_plan.steps[stage_index].input_names) |name| {
        const input = native_plan.findStage(name) orelse continue;
        const found = findPartitionScanRoot(
            definition_plan,
            native_plan,
            input,
            relation,
            depth + 1,
        ) catch continue;
        return found;
    }
    return error.ObservationPhysicalScanMissing;
}

fn executeObservation(
    allocator: std.mem.Allocator,
    args: *const ObserveArgs,
    context: *const seq.compiled_plan.PlanSet,
    program: *const seq.execution.Program,
    output: []seq.execution.Value,
) !ObservationExecution {
    return switch (program.source) {
        .physical => |relation| executePhysicalObservation(
            allocator,
            args,
            context,
            program,
            relation,
            output,
        ),
        .external => |input_index| executeExternalObservation(
            allocator,
            args,
            context,
            program,
            input_index,
            output,
        ),
    };
}

fn executePhysicalObservation(
    allocator: std.mem.Allocator,
    args: *const ObserveArgs,
    context: *const seq.compiled_plan.PlanSet,
    program: *const seq.execution.Program,
    relation: seq.physical.Relation,
    output: []seq.execution.Value,
) !ObservationExecution {
    if (args.input_specs.len != 0) {
        return error.ExternalInputNotAcceptedForPhysicalObservation;
    }
    try validateSelectedSelectors(&context.definition_plan, args.selectors);
    var discovery_selectors = args.selectors;
    discovery_selectors.session_id = null;
    var paths = try seq.native.resolveTargetPaths(
        allocator,
        defaultIo(),
        discovery_selectors,
        false,
    );
    defer seq.native.freePaths(allocator, &paths);
    var runner = try seq.execution.Runner.initOwnedAllocBounded(
        allocator,
        program,
        output,
        context.definition_plan.bounds.max_output_bytes,
    );
    errdefer runner.deinit();
    var metrics = PhysicalMetrics{};
    var digest_set = CorpusSetHasher{};
    for (paths.items) |path| {
        const feed = try feedPhysicalFile(
            allocator,
            args,
            program,
            relation,
            path,
            context.definition_plan.bounds,
            &runner,
            &digest_set,
            &metrics,
        );
        if (feed == .stop and args.selectors.session_id == null) break;
    }
    if (args.selectors.session_id != null) {
        if (metrics.sessions == 0) return error.SessionNotFound;
        if (metrics.sessions != 1) return error.AmbiguousSessionTarget;
    }
    return .{
        .result = try runner.finish(),
        .runner = runner,
        .corpus_adapter = metrics.adapter orelse "codex-rollout-jsonl/v1",
        .corpus_digest = digest_set.digest(),
        .corpus_files = metrics.files,
        .corpus_sessions = metrics.sessions,
        .files_opened = metrics.opened,
        .bytes_read = metrics.bytes_read,
        .warning_count = metrics.warnings,
    };
}

const PhysicalMetrics = struct {
    files: usize = 0,
    sessions: usize = 0,
    opened: usize = 0,
    bytes_read: usize = 0,
    corpus_bytes: usize = 0,
    warnings: usize = 0,
    adapter: ?[]const u8 = null,

    fn admitAdapter(self: *PhysicalMetrics, adapter: []const u8) !void {
        if (self.adapter) |current| {
            if (!std.mem.eql(u8, current, adapter)) {
                return error.MixedPhysicalSourceAdapters;
            }
        } else {
            self.adapter = adapter;
        }
    }
};

fn feedPhysicalFile(
    allocator: std.mem.Allocator,
    args: *const ObserveArgs,
    program: *const seq.execution.Program,
    relation: seq.physical.Relation,
    path: []const u8,
    bounds: seq.definition.Bounds,
    runner: *seq.execution.Runner,
    digest_set: *CorpusSetHasher,
    metrics: *PhysicalMetrics,
) !seq.execution.Feed {
    if (seq.opencode_adapter.recognizes(path)) {
        return feedOpenCodeFile(
            allocator,
            args,
            program,
            path,
            bounds,
            runner,
            digest_set,
            metrics,
        );
    }
    return feedCodexFile(
        allocator,
        args,
        program,
        relation,
        path,
        bounds,
        runner,
        digest_set,
        metrics,
    );
}

fn feedOpenCodeFile(
    allocator: std.mem.Allocator,
    args: *const ObserveArgs,
    program: *const seq.execution.Program,
    path: []const u8,
    bounds: seq.definition.Bounds,
    runner: *seq.execution.Runner,
    digest_set: *CorpusSetHasher,
    metrics: *PhysicalMetrics,
) !seq.execution.Feed {
    if (args.selectors.repo != null or
        args.selectors.since_ms != null or
        args.selectors.until_ms != null)
    {
        return error.OpenCodePromptHistorySelectorUnavailable;
    }
    if (!try openCodeSessionPasses(args, program, path)) {
        return .continue_scanning;
    }
    const remaining_bytes = if (metrics.corpus_bytes < bounds.max_input_bytes)
        bounds.max_input_bytes - metrics.corpus_bytes
    else
        return error.ObservationInputByteBoundExceeded;
    const observed = try seq.opencode_adapter.feedFile(
        allocator,
        program,
        runner,
        path,
        remaining_bytes,
    );
    try metrics.admitAdapter(seq.opencode_adapter.adapter_id);
    metrics.opened += 1;
    metrics.bytes_read = try std.math.add(
        usize,
        metrics.bytes_read,
        observed.bytes_read,
    );
    metrics.corpus_bytes = try std.math.add(
        usize,
        metrics.corpus_bytes,
        observed.bytes_read,
    );
    metrics.warnings = try std.math.add(
        usize,
        metrics.warnings,
        observed.warnings,
    );
    metrics.files += 1;
    metrics.sessions += 1;
    digest_set.add(path, &observed.digest);
    return if (runner.stopped) .stop else .continue_scanning;
}

fn openCodeSessionPasses(
    args: *const ObserveArgs,
    program: *const seq.execution.Program,
    path: []const u8,
) !bool {
    const wanted = args.selectors.session_id;
    const excluded = seq.execution.excludedSessionId(program);
    if (wanted == null and excluded == null) return true;
    var buffer: [64]u8 = undefined;
    const actual = try seq.opencode_adapter.sessionId(&buffer, path);
    if (wanted) |value| {
        if (!std.mem.eql(u8, value, actual)) return false;
    }
    if (excluded) |value| {
        if (std.mem.eql(u8, value, actual)) return false;
    }
    return true;
}

fn feedCodexFile(
    allocator: std.mem.Allocator,
    args: *const ObserveArgs,
    program: *const seq.execution.Program,
    relation: seq.physical.Relation,
    path: []const u8,
    bounds: seq.definition.Bounds,
    runner: *seq.execution.Runner,
    digest_set: *CorpusSetHasher,
    metrics: *PhysicalMetrics,
) !seq.execution.Feed {
    const selected = try seq.trace_adapter.parseFileSelected(
        allocator,
        program,
        path,
        .{
            .max_input_bytes = if (metrics.corpus_bytes < bounds.max_input_bytes)
                bounds.max_input_bytes - metrics.corpus_bytes
            else
                0,
        },
        .{
            .session_id = args.selectors.session_id,
            .exclude_session_id = seq.execution.excludedSessionId(program),
            .repo = args.selectors.repo,
            .since_ms = args.selectors.since_ms,
            .until_ms = args.selectors.until_ms,
            .filter_time = relation == .sessions,
        },
    );
    if (selected.file_opened) metrics.opened += 1;
    try recordDiscoveryBytes(metrics, selected.discovery_bytes_read);
    var parsed = selected.parsed orelse return .continue_scanning;
    defer parsed.deinit(allocator);
    try metrics.admitAdapter("codex-rollout-jsonl/v1");
    try recordCorpusBytes(metrics, parsed.metrics.bytes_read);
    if (relation == .sessions) {
        if (!seq.native.sessionPasses(
            parsed.trace.session,
            args.selectors,
        )) return .continue_scanning;
    } else if (!seq.native.sessionMetadataPasses(
        parsed.trace.session,
        args.selectors,
    )) {
        return .continue_scanning;
    }
    try admitCodexSession(metrics, &parsed);
    digest_set.add(path, &parsed.corpus_digest);
    return feedCodexRows(
        allocator,
        args,
        program,
        relation,
        bounds,
        runner,
        &parsed,
    );
}

fn recordDiscoveryBytes(metrics: *PhysicalMetrics, bytes: usize) !void {
    metrics.bytes_read = std.math.add(
        usize,
        metrics.bytes_read,
        bytes,
    ) catch return error.ObservationMetricOverflow;
    if (metrics.bytes_read > max_discovery_bytes + metrics.corpus_bytes) {
        return error.ObservationDiscoveryByteBoundExceeded;
    }
}

fn recordCorpusBytes(metrics: *PhysicalMetrics, bytes: usize) !void {
    metrics.bytes_read = std.math.add(
        usize,
        metrics.bytes_read,
        bytes,
    ) catch return error.ObservationMetricOverflow;
    metrics.corpus_bytes = std.math.add(
        usize,
        metrics.corpus_bytes,
        bytes,
    ) catch return error.ObservationMetricOverflow;
}

fn admitCodexSession(
    metrics: *PhysicalMetrics,
    parsed: *const seq.trace_adapter.ParsedTrace,
) !void {
    metrics.warnings = std.math.add(
        usize,
        metrics.warnings,
        parsed.trace.warnings.items.len,
    ) catch return error.ObservationMetricOverflow;
    metrics.files += 1;
    metrics.sessions += 1;
}

fn feedCodexRows(
    allocator: std.mem.Allocator,
    args: *const ObserveArgs,
    program: *const seq.execution.Program,
    relation: seq.physical.Relation,
    bounds: seq.definition.Bounds,
    runner: *seq.execution.Runner,
    parsed: *const seq.trace_adapter.ParsedTrace,
) !seq.execution.Feed {
    return switch (relation) {
        .structured_documents, .structured_values => result: {
            var index = try seq.structured.build(
                allocator,
                &parsed.trace,
                relation == .structured_values,
                structuredLimitsFor(bounds),
            );
            defer index.deinit(allocator);
            break :result try seq.structured.feedSelected(
                runner,
                program,
                &index,
                args.selectors.since_ms,
                args.selectors.until_ms,
            );
        },
        else => try seq.trace_adapter.feedTraceSelected(
            runner,
            program,
            &parsed.trace,
            .{
                .since_ms = args.selectors.since_ms,
                .until_ms = args.selectors.until_ms,
            },
        ),
    };
}

fn structuredLimitsFor(
    bounds: seq.definition.Bounds,
) seq.structured.Limits {
    return .{
        .max_documents = bounds.max_graph_nodes,
        .max_document_bytes = bounds.max_input_bytes,
        .max_values = bounds.max_graph_nodes,
        .max_depth = bounds.max_graph_depth,
        .max_owned_bytes = @min(
            bounds.max_input_bytes,
            bounds.max_output_bytes,
        ),
    };
}

fn executeExternalObservation(
    allocator: std.mem.Allocator,
    args: *const ObserveArgs,
    context: *const seq.compiled_plan.PlanSet,
    program: *const seq.execution.Program,
    input_index: u16,
    output: []seq.execution.Value,
) !ObservationExecution {
    if (hasPhysicalSelector(args.selectors)) {
        return error.PhysicalSelectorNotAcceptedForExternalObservation;
    }
    if (input_index >= context.definition_plan.inputs.len) {
        return error.ExternalInputProgramMismatch;
    }
    const input_name = context.definition_plan.inputs[input_index].name;
    var relation = try loadExternalInput(
        allocator,
        &context.definition_plan,
        input_name,
        args.input_specs,
    );
    errdefer relation.deinit(allocator);
    const result = try seq.external_input.execute(
        allocator,
        program,
        &relation,
        output,
    );
    const files_opened: usize = if (externalInputIsStdin(args.input_specs))
        0
    else
        1;
    return .{
        .result = result,
        .external_relation = relation,
        .corpus_adapter = "immutable-relation-json/v1",
        .corpus_digest = relation.raw_digest,
        .corpus_files = files_opened,
        .corpus_sessions = 0,
        .files_opened = files_opened,
        .bytes_read = relation.input_bytes,
    };
}

fn externalInputIsStdin(specs: []const []const u8) bool {
    if (specs.len != 1) return false;
    const separator = std.mem.indexOfScalar(u8, specs[0], '=') orelse
        return false;
    return std.mem.eql(u8, specs[0][separator + 1 ..], "-");
}

fn observationLimitations(
    warning_count: usize,
    projection_bounded: bool,
) []const []const u8 {
    if (warning_count != 0 and projection_bounded) {
        return &.{
            "selected corpus contains parser warnings; evidence may be incomplete",
            "projection is definition-bounded; additional matching evidence may be omitted",
        };
    }
    if (warning_count != 0) {
        return &.{
            "selected corpus contains parser warnings; evidence may be incomplete",
        };
    }
    if (projection_bounded) {
        return &.{
            "projection is definition-bounded; additional matching evidence may be omitted",
        };
    }
    return &.{};
}

fn programMayTruncate(program: *const seq.execution.Program) bool {
    for (program.operations) |operation| {
        switch (operation) {
            .limit, .top_k => return true,
            else => {},
        }
    }
    return false;
}

fn renderObservationAlloc(
    allocator: std.mem.Allocator,
    base: seq.result.Envelope,
    stats: *definition_core.result.ExecutionStats,
) ![]u8 {
    var envelope = base;
    envelope.execution_stats = stats.*;
    const rendered = try seq.result.renderJsonAlloc(allocator, envelope);
    stats.output_bytes = rendered.len;
    return rendered;
}

fn parseDefinitionArgs(argv: []const []const u8) !DefinitionArgs {
    var definition_path: ?[]const u8 = null;
    var format: Format = .json;
    var format_seen = false;
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
        return error.UnknownOption;
    }
    return .{
        .definition_path = definition_path orelse
            return error.MissingDefinition,
        .format = format,
    };
}

const ObserveOption = enum {
    definition,
    projection,
    path,
    root,
    session_id,
    repo,
    since,
    until,
    last,
    input,
    parameter,
    format,

    fn parse(token: []const u8) !ObserveOption {
        if (std.mem.eql(u8, token, "--definition")) return .definition;
        if (std.mem.eql(u8, token, "--projection")) return .projection;
        if (std.mem.eql(u8, token, "--path")) return .path;
        if (std.mem.eql(u8, token, "--root")) return .root;
        if (std.mem.eql(u8, token, "--session-id")) return .session_id;
        if (std.mem.eql(u8, token, "--repo")) return .repo;
        if (std.mem.eql(u8, token, "--since")) return .since;
        if (std.mem.eql(u8, token, "--until")) return .until;
        if (std.mem.eql(u8, token, "--last")) return .last;
        if (std.mem.eql(u8, token, "--input")) return .input;
        if (std.mem.eql(u8, token, "--param")) return .parameter;
        if (std.mem.eql(u8, token, "--format")) return .format;
        return error.UnknownOption;
    }
};

const ObserveParseState = struct {
    definition_path: ?[]const u8 = null,
    projection: ?[]const u8 = null,
    selectors: seq.native.Options = .{},
    format: Format = .json,
    format_seen: bool = false,
    inputs: std.ArrayList([]const u8) = .empty,
    parameters: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *ObserveParseState, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
        self.parameters.deinit(allocator);
        self.* = undefined;
    }

    fn apply(
        self: *ObserveParseState,
        allocator: std.mem.Allocator,
        option: ObserveOption,
        value: []const u8,
    ) !void {
        switch (option) {
            .definition => try setOnce(
                &self.definition_path,
                value,
                error.DuplicateDefinitionOption,
            ),
            .projection => try setOnce(
                &self.projection,
                value,
                error.DuplicateProjectionOption,
            ),
            .path => try setOnce(
                &self.selectors.path,
                value,
                error.DuplicatePathOption,
            ),
            .root => try setOnce(
                &self.selectors.root,
                value,
                error.DuplicateRootOption,
            ),
            .session_id => try setOnce(
                &self.selectors.session_id,
                value,
                error.DuplicateSessionIdOption,
            ),
            .repo => try setOnce(
                &self.selectors.repo,
                value,
                error.DuplicateRepoOption,
            ),
            .since => try setOnce(
                &self.selectors.since,
                value,
                error.DuplicateSinceOption,
            ),
            .until => try setOnce(
                &self.selectors.until,
                value,
                error.DuplicateUntilOption,
            ),
            .last => try setOnce(
                &self.selectors.last,
                value,
                error.DuplicateLastOption,
            ),
            .input => try self.inputs.append(allocator, value),
            .parameter => try self.parameters.append(allocator, value),
            .format => {
                if (self.format_seen) return error.DuplicateFormatOption;
                self.format_seen = true;
                self.format = try Format.parse(value);
            },
        }
    }

    fn finish(
        self: *ObserveParseState,
        allocator: std.mem.Allocator,
    ) !ObserveArgs {
        const definition_path = self.definition_path orelse
            return error.MissingDefinition;
        const projection = self.projection orelse
            return error.MissingProjection;
        if (self.selectors.path != null and
            (self.selectors.root != null or
                self.selectors.session_id != null))
        {
            return error.ConflictingSessionSelectors;
        }
        try seq.native.resolveTemporalBounds(&self.selectors);
        const input_specs = try self.inputs.toOwnedSlice(allocator);
        errdefer allocator.free(input_specs);
        const parameter_specs =
            try self.parameters.toOwnedSlice(allocator);
        return .{
            .definition_path = definition_path,
            .projection = projection,
            .selectors = self.selectors,
            .input_specs = input_specs,
            .parameter_specs = parameter_specs,
            .format = self.format,
        };
    }
};

fn setOnce(
    slot: *?[]const u8,
    value: []const u8,
    duplicate_error: anyerror,
) !void {
    if (slot.* != null) return duplicate_error;
    slot.* = value;
}

fn parseObserveArgs(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !ObserveArgs {
    var state = ObserveParseState{};
    defer state.deinit(allocator);
    var index: usize = 0;
    while (index < argv.len) {
        const option = try ObserveOption.parse(argv[index]);
        index += 1;
        if (index >= argv.len) return error.MissingOptionValue;
        try state.apply(allocator, option, argv[index]);
        index += 1;
    }
    return state.finish(allocator);
}

fn hasPhysicalSelector(options: seq.native.Options) bool {
    return options.root != null or
        options.path != null or
        options.session_id != null or
        options.repo != null or
        options.since != null or
        options.until != null or
        options.last != null;
}

fn validateSelectedSelectors(
    definition_plan: *const seq.definition.Plan,
    options: seq.native.Options,
) !void {
    const selected = [_]struct {
        active: bool,
        selector: seq.definition.Selector,
    }{
        .{ .active = options.root != null, .selector = .root },
        .{ .active = options.session_id != null, .selector = .session_id },
        .{ .active = options.path != null, .selector = .path },
        .{ .active = options.repo != null, .selector = .repo },
        .{ .active = options.since != null, .selector = .since },
        .{ .active = options.until != null, .selector = .until },
        .{ .active = options.last != null, .selector = .last },
    };
    for (selected) |item| {
        if (item.active and
            !selectorAllowed(definition_plan, item.selector))
        {
            return error.ObservationSelectorNotDeclared;
        }
    }
    if (options.path == null and
        !selectorAllowed(definition_plan, .root))
    {
        return error.MissingPathSelector;
    }
}

const CorpusSetHasher = struct {
    hasher: std.crypto.hash.sha2.Sha256 = init: {
        var value = std.crypto.hash.sha2.Sha256.init(.{});
        value.update("seq-corpus-set/v1\x00");
        break :init value;
    },

    fn add(
        self: *CorpusSetHasher,
        path: []const u8,
        file_digest: []const u8,
    ) void {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(path.len), .big);
        self.hasher.update(&length);
        self.hasher.update(path);
        self.hasher.update(file_digest);
    }

    fn digest(self: CorpusSetHasher) [71]u8 {
        var mutable = self;
        var raw: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        mutable.hasher.final(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        var encoded: [71]u8 = undefined;
        @memcpy(encoded[0..7], "sha256:");
        @memcpy(encoded[7..], &hex);
        return encoded;
    }
};

fn loadDefinition(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    path: []const u8,
    request: seq.compiled_plan.Request,
) !seq.compiled_plan.PlanSet {
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
    const cache_dir = try seqCacheDirAlloc(allocator, environment);
    defer if (cache_dir) |owned| allocator.free(owned);
    return seq.compiled_plan.load(
        allocator,
        location.root,
        location.entry,
        request,
        Version,
        source_adapter_version,
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

fn seqCacheDirAlloc(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
) !?[]u8 {
    var base: []const u8 = undefined;
    var suffix: []const u8 = undefined;
    if (environmentValue(environment, "SEQ_CACHE_DIR")) |value| {
        base = value;
        suffix = "definitions";
    } else if (environmentValue(environment, "XDG_CACHE_HOME")) |value| {
        base = value;
        suffix = "seq/definitions";
    } else if (environmentValue(environment, "HOME")) |value| {
        base = value;
        suffix = ".cache/seq/definitions";
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

fn loadExternalInput(
    allocator: std.mem.Allocator,
    definition_plan: *const seq.definition.Plan,
    expected_name: []const u8,
    specs: []const []const u8,
) !seq.external_input.Relation {
    if (specs.len != 1) return error.ExpectedOneExternalInput;
    const separator = std.mem.indexOfScalar(u8, specs[0], '=') orelse
        return error.InvalidInputBinding;
    if (separator == 0 or separator + 1 >= specs[0].len) {
        return error.InvalidInputBinding;
    }
    const name = specs[0][0..separator];
    const source = specs[0][separator + 1 ..];
    if (!std.mem.eql(u8, name, expected_name)) {
        return error.ExternalInputProgramMismatch;
    }
    if (!std.mem.eql(u8, source, "-")) {
        return seq.external_input.loadFile(
            allocator,
            definition_plan,
            name,
            source,
        );
    }
    const input = findInput(definition_plan.inputs, name) orelse
        return error.UnknownExternalInput;
    const max_bytes = @min(
        input.max_bytes,
        definition_plan.bounds.max_input_bytes,
    );
    var stdin_reader = std.Io.File.stdin().reader(defaultIo(), &.{});
    const bytes = try stdin_reader.interface.allocRemaining(
        allocator,
        .limited(max_bytes),
    );
    defer allocator.free(bytes);
    return seq.external_input.parseBytes(
        allocator,
        definition_plan,
        name,
        bytes,
    );
}

fn bindParameters(
    allocator: std.mem.Allocator,
    declarations: *const definition_core.parameters.Declarations,
    specs: []const []const u8,
) !definition_core.parameters.Bindings {
    const inputs = try allocator.alloc(
        definition_core.parameters.Input,
        specs.len,
    );
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

fn emitCapabilities(argv: []const []const u8) !u8 {
    var format: Format = .json;
    var format_seen = false;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        if (!std.mem.eql(u8, argv[index], "--format")) {
            return error.UnknownOption;
        }
        index += 1;
        if (index >= argv.len) return error.MissingOptionValue;
        if (format_seen) return error.DuplicateFormatOption;
        format_seen = true;
        format = try Format.parse(argv[index]);
    }
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    if (format == .text) {
        try stdout_writer.interface.print(
            "Seq {s}\nABI: {s}\n",
            .{ Version, seq.definition.abi },
        );
        return 0;
    }
    try stdout_writer.interface.print(
        "{{\"schema\":\"seq-capabilities/v1\",\"version\":\"{s}\"," ++
            "\"observation_abis\":[\"{s}\"],\"source_adapters\":" ++
            "[\"codex-rollout-jsonl/v1\"," ++
            "\"opencode-prompt-history-jsonl/v1\"," ++
            "\"immutable-relation-json/v1\"],\"operators\":[",
        .{ Version, seq.definition.abi },
    );
    var first = true;
    for (std.enums.values(seq.definition.Operator)) |operator| {
        if (!seq.plan.supports(operator)) continue;
        if (!first) try stdout_writer.interface.writeByte(',');
        first = false;
        try stdout_writer.interface.writeAll("{\"id\":");
        try writeString(&stdout_writer.interface, operator.id());
        try stdout_writer.interface.print(
            ",\"version\":{d}}}",
            .{operator.version()},
        );
    }
    try stdout_writer.interface.print(
        "],\"renderers\":[\"json\"],\"cache_format\":{d}," ++
            "\"limits\":{{\"max_output_cells\":{d}}}," ++
            "\"result_schemas\":[\"seq-capabilities/v1\"," ++
            "\"seq-command-error/v1\"," ++
            "\"seq-definition-check-result/v1\"," ++
            "\"seq-definition-description/v1\"," ++
            "\"seq-index-result/v1\"," ++
            "\"seq-observation-plan/v1\"," ++
            "\"seq-observation-result/v1\"]}}\n",
        .{ definition_core.cache.format_version, max_output_cells },
    );
    return 0;
}

fn writeCompileStats(
    writer: *std.Io.Writer,
    stats: definition_core.result.CompileStats,
) !void {
    try writer.print(
        "{{\"cache_hit\":{},\"cache_write_failed\":{}," ++
            "\"compile_ns\":{d},\"closure_files\":{d}," ++
            "\"closure_bytes\":{d}}}",
        .{
            stats.cache_hit,
            stats.cache_write_failed,
            stats.compile_ns,
            stats.closure_files,
            stats.closure_bytes,
        },
    );
}

fn emitCommandError(err: anyerror) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(
        "{\"schema\":\"seq-command-error/v1\",\"code\":",
    );
    try writeString(&stdout_writer.interface, @errorName(err));
    try stdout_writer.interface.writeAll(
        ",\"authority_granted\":false}\n",
    );
}

fn findProjection(
    projections: []const seq.definition.Projection,
    name: []const u8,
) ?*const seq.definition.Projection {
    for (projections) |*projection| {
        if (std.mem.eql(u8, projection.name, name)) return projection;
    }
    return null;
}

fn findInput(
    inputs: []const seq.definition.ExternalInput,
    name: []const u8,
) ?seq.definition.ExternalInput {
    for (inputs) |input| {
        if (std.mem.eql(u8, input.name, name)) return input;
    }
    return null;
}

fn selectorAllowed(
    plan: *const seq.definition.Plan,
    selector: seq.definition.Selector,
) bool {
    const bit = @as(u8, 1) << @intCast(@intFromEnum(selector));
    return (plan.selector_mask & bit) != 0;
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try definition_core.canonical_json.writeCanonicalString(writer, value);
}

fn environmentValue(
    environment: *const std.process.Environ.Map,
    key: []const u8,
) ?[]const u8 {
    const value = environment.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

fn monotonicNanoseconds() i128 {
    var timestamp: std.posix.timespec = undefined;
    return switch (std.posix.errno(std.posix.system.clock_gettime(
        .MONOTONIC,
        &timestamp,
    ))) {
        .SUCCESS => @as(i128, timestamp.sec) * std.time.ns_per_s +
            timestamp.nsec,
        else => 0,
    };
}

fn elapsedNanoseconds(start: i128) u64 {
    const finish = monotonicNanoseconds();
    if (finish <= start) return 0;
    return std.math.cast(u64, finish - start) orelse std.math.maxInt(u64);
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
    return std.mem.eql(u8, token, "-h") or
        std.mem.eql(u8, token, "--help");
}

fn isOnlyHelp(argv: []const []const u8) bool {
    return argv.len == 1 and isHelp(argv[0]);
}

fn isVersion(token: []const u8) bool {
    return std.mem.eql(u8, token, "-V") or
        std.mem.eql(u8, token, "--version");
}

fn isHostSequenceInvocation(argv: []const []const u8) bool {
    if (!std.process.can_replace or argv.len == 0) return false;
    const first = argv[0];
    if (isHostSequenceOperand(first)) return true;
    inline for (.{ "-f", "-s", "-t", "-w" }) |option| {
        if (std.mem.startsWith(u8, first, option)) return true;
    }
    inline for (.{ "--format", "--separator", "--equal-width" }) |option| {
        if (std.mem.eql(u8, first, option) or
            (std.mem.startsWith(u8, first, option) and
                first.len > option.len and first[option.len] == '='))
        {
            return true;
        }
    }
    return false;
}

fn isHostSequenceOperand(raw: []const u8) bool {
    if (raw.len == 0) return false;
    const offset: usize = if (raw[0] == '+' or raw[0] == '-') 1 else 0;
    if (offset == raw.len) return false;
    return std.ascii.isDigit(raw[offset]) or raw[offset] == '.';
}

test "final command surface contains no skill or artifact commands" {
    try std.testing.expect(
        std.mem.indexOf(u8, Help, "skill-decision-audit") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, Help, "execution-policy-compile") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, Help, "definition check") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, Help, "observe") != null);
}

test "host numeric seq syntax is disjoint from the product command surface" {
    try std.testing.expect(isHostSequenceInvocation(&.{"1"}));
    try std.testing.expect(isHostSequenceInvocation(&.{ "-1", "1" }));
    try std.testing.expect(isHostSequenceInvocation(&.{ "-w", "1", "9" }));
    try std.testing.expect(isHostSequenceInvocation(&.{
        "--format=%02g",
        "1",
        "9",
    }));
    try std.testing.expect(!isHostSequenceInvocation(&.{"version"}));
    try std.testing.expect(!isHostSequenceInvocation(&.{"sessions"}));
    try std.testing.expect(!isHostSequenceInvocation(&.{"--help"}));
    try std.testing.expect(!isHostSequenceInvocation(&.{"--future"}));
}

test "observe parser accepts explicit definition selectors and parameters" {
    var args = try parseObserveArgs(std.testing.allocator, &.{
        "--definition",
        "observation.json",
        "--projection",
        "rows",
        "--path",
        "rollout.jsonl",
        "--param",
        "needle=failure",
        "--format",
        "json",
    });
    defer args.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("rows", args.projection);
    try std.testing.expectEqualStrings(
        "rollout.jsonl",
        args.selectors.path.?,
    );
    try std.testing.expectEqual(@as(usize, 1), args.parameter_specs.len);
}

test "selected parser warnings contaminate the observation envelope" {
    try std.testing.expectEqual(
        @as(usize, 0),
        observationLimitations(0, false).len,
    );
    const limitations = observationLimitations(1, false);
    try std.testing.expectEqual(@as(usize, 1), limitations.len);
    try std.testing.expectEqualStrings(
        "selected corpus contains parser warnings; evidence may be incomplete",
        limitations[0],
    );
    const bounded = observationLimitations(0, true);
    try std.testing.expectEqual(@as(usize, 1), bounded.len);
    try std.testing.expectEqualStrings(
        "projection is definition-bounded; additional matching evidence may be omitted",
        bounded[0],
    );
}
