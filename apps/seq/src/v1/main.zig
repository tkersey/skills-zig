const std = @import("std");
const app_meta = @import("app_meta");
const definition_core = @import("definition_core");
const seq = @import("seq_v1_core");

const Version = std.mem.trim(u8, app_meta.version, " \t\r\n");
const source_adapter_version = "seq-source-adapter-set/v1";
const max_output_cells: usize = 4_000_000;
threadlocal var runtime_io: ?std.Io = null;

const Help =
    \\seq
    \\
    \\Provenance-preserving observations over agent execution and session evidence.
    \\
    \\usage: seq <command> [options]
    \\
    \\commands:
    \\  definition check
    \\  definition describe
    \\  observe
    \\  explain
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
    \\  capabilities
    \\  version
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
    if (std.mem.eql(u8, argv[1], "observe")) {
        return runObserve(allocator, environment, argv[2..]);
    }
    if (std.mem.eql(u8, argv[1], "explain")) {
        return runExplain(allocator, environment, argv[2..]);
    }
    if (seq.native.Command.parse(argv[1])) |command| {
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        return seq.native.run(
            allocator,
            environment,
            command,
            argv[2..],
            &stdout_writer.interface,
            defaultIo(),
        );
    }
    return error.UnknownCommand;
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

    fn deinit(self: *ObservationExecution, allocator: std.mem.Allocator) void {
        if (self.runner) |*runner| runner.deinit();
        if (self.external_relation) |*relation| relation.deinit(allocator);
        self.* = undefined;
    }
};

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
    var paths = try seq.native.resolveTargetPaths(
        allocator,
        defaultIo(),
        args.selectors,
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
        if (feed == .stop) break;
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
    if (args.selectors.session_id) |wanted| {
        if (!std.mem.eql(
            u8,
            wanted,
            seq.opencode_adapter.session_id,
        )) return .continue_scanning;
    }
    const remaining_bytes = if (metrics.bytes_read < bounds.max_input_bytes)
        bounds.max_input_bytes - metrics.bytes_read
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
    var parsed = try seq.trace_adapter.parseFile(
        allocator,
        program,
        path,
        .{
            .max_input_bytes = if (metrics.bytes_read < bounds.max_input_bytes)
                bounds.max_input_bytes - metrics.bytes_read
            else
                0,
        },
    );
    defer parsed.deinit(allocator);
    try metrics.admitAdapter("codex-rollout-jsonl/v1");
    metrics.opened += 1;
    metrics.bytes_read = std.math.add(
        usize,
        metrics.bytes_read,
        parsed.metrics.bytes_read,
    ) catch return error.ObservationMetricOverflow;
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
    metrics.warnings = std.math.add(
        usize,
        metrics.warnings,
        parsed.trace.warnings.items.len,
    ) catch return error.ObservationMetricOverflow;
    metrics.files += 1;
    metrics.sessions += 1;
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
    return .{
        .result = result,
        .external_relation = relation,
        .corpus_adapter = "immutable-relation-json/v1",
        .corpus_digest = relation.raw_digest,
        .corpus_files = 1,
        .corpus_sessions = 0,
        .files_opened = 1,
        .bytes_read = relation.input_bytes,
    };
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
    var expected_bytes: usize = 0;
    for (0..8) |_| {
        stats.output_bytes = expected_bytes;
        var envelope = base;
        envelope.execution_stats = stats.*;
        const rendered = try seq.result.renderJsonAlloc(allocator, envelope);
        if (rendered.len == expected_bytes) return rendered;
        expected_bytes = rendered.len;
        allocator.free(rendered);
    }
    return error.ObservationOutputSizeDidNotConverge;
}

fn parseDefinitionArgs(argv: []const []const u8) !DefinitionArgs {
    var definition_path: ?[]const u8 = null;
    var format: Format = .json;
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
            .format => self.format = try Format.parse(value),
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
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        if (!std.mem.eql(u8, argv[index], "--format")) {
            return error.UnknownOption;
        }
        index += 1;
        if (index >= argv.len) return error.MissingOptionValue;
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
            "\"result_schemas\":[\"seq-observation-result/v1\"]}}\n",
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

fn isVersion(token: []const u8) bool {
    return std.mem.eql(u8, token, "-V") or
        std.mem.eql(u8, token, "--version");
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
