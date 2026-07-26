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
    \\Definitions are passive JSON. Seq reports observations and limitations; it never grants authority.
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
    path: ?[]const u8,
    input_specs: []const []const u8,
    parameter_specs: []const []const u8,
    format: Format,

    fn deinit(self: *ObserveArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.input_specs);
        allocator.free(self.parameter_specs);
        self.* = undefined;
    }
};

const DefinitionLocation = struct {
    root: []u8,
    entry: []u8,

    fn deinit(self: *DefinitionLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.entry);
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
    if (std.mem.eql(u8, argv[1], "observe")) {
        return runObserve(allocator, argv[2..]);
    }
    return error.UnknownCommand;
}

fn runDefinitionCheck(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !u8 {
    const args = try parseDefinitionArgs(argv);
    var context = try loadDefinition(
        allocator,
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
    argv: []const []const u8,
) !u8 {
    const args = try parseDefinitionArgs(argv);
    var context = try loadDefinition(
        allocator,
        args.definition_path,
        .{},
    );
    defer context.deinit(allocator);
    switch (args.format) {
        .json => {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try output.writer.writeAll(
                "{\"schema\":\"seq-definition-description/v1\",\"definition\":{\"id\":",
            );
            try writeString(&output.writer, context.definition_plan.id);
            try output.writer.writeAll(",\"digest\":");
            try writeString(
                &output.writer,
                &context.definition_plan.closure_digest,
            );
            try output.writer.writeAll(",\"abi\":\"");
            try output.writer.writeAll(seq.definition.abi);
            try output.writer.writeAll("\"},\"operators\":[");
            var first = true;
            for (std.enums.values(seq.definition.Operator)) |operator| {
                if (!context.definition_plan.requires(operator)) continue;
                if (!first) try output.writer.writeByte(',');
                first = false;
                try writeString(&output.writer, operator.id());
            }
            try output.writer.writeAll("],\"selectors\":[");
            first = true;
            for (std.enums.values(seq.definition.Selector)) |selector| {
                if (!selectorAllowed(&context.definition_plan, selector)) {
                    continue;
                }
                if (!first) try output.writer.writeByte(',');
                first = false;
                try writeString(&output.writer, selector.id());
            }
            try output.writer.writeAll("],\"projections\":[");
            for (context.definition_plan.projections, 0..) |projection, index| {
                if (index != 0) try output.writer.writeByte(',');
                try writeString(&output.writer, projection.name);
            }
            try output.writer.writeAll("],\"compile_stats\":");
            try writeCompileStats(&output.writer, context.stats);
            try output.writer.writeAll(
                ",\"passive\":true,\"authority_granted\":false}\n",
            );
            try writeStdout(output.written());
        },
        .text => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print(
                "{s}\ndigest: {s}\nabi: {s}\n",
                .{
                    context.definition_plan.id,
                    context.definition_plan.closure_digest[0..],
                    seq.definition.abi,
                },
            );
        },
    }
    return 0;
}

fn runObserve(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !u8 {
    var args = try parseObserveArgs(allocator, argv);
    defer args.deinit(allocator);
    if (args.format != .json) return error.UnsupportedObservationRenderer;
    const projection_names = [_][]const u8{args.projection};
    var context = try loadDefinition(
        allocator,
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
    var rows: seq.execution.Rows = undefined;
    var corpus_adapter: []const u8 = undefined;
    var corpus_digest: []const u8 = undefined;
    var files_opened: usize = 0;
    var bytes_read: usize = 0;
    var rows_materialized: usize = 0;
    var physical_observation: ?seq.trace_adapter.Observation = null;
    defer if (physical_observation) |*observation| {
        observation.deinit(allocator);
    };
    var external_relation: ?seq.external_input.Relation = null;
    defer if (external_relation) |*relation| relation.deinit(allocator);

    const result = switch (program.source) {
        .physical => physical_result: {
            if (args.input_specs.len != 0) {
                return error.ExternalInputNotAcceptedForPhysicalObservation;
            }
            const path = args.path orelse return error.MissingPathSelector;
            if (!selectorAllowed(
                &context.definition_plan,
                .path,
            )) return error.ObservationSelectorNotDeclared;
            physical_observation = try seq.trace_adapter.observeFile(
                allocator,
                &program,
                path,
                .{},
                output,
            );
            const observation = &physical_observation.?;
            corpus_adapter = "codex-rollout-jsonl/v1";
            corpus_digest = &observation.corpus_digest;
            files_opened = 1;
            bytes_read = observation.metrics.bytes_read;
            break :physical_result observation.result;
        },
        .external => |input_index| external_result: {
            if (args.path != null) return error.PathSelectorNotAccepted;
            if (input_index >= context.definition_plan.inputs.len) {
                return error.ObservationExternalInputIndexInvalid;
            }
            external_relation = try loadExternalInput(
                allocator,
                &context.definition_plan,
                context.definition_plan.inputs[input_index].name,
                args.input_specs,
            );
            const relation = &external_relation.?;
            corpus_adapter = "immutable-relation-json/v1";
            corpus_digest = &relation.raw_digest;
            files_opened = 1;
            bytes_read = relation.input_bytes;
            break :external_result try seq.external_input.execute(
                allocator,
                &program,
                relation,
                output,
            );
        },
    };
    rows_materialized = result.materialized_row_count;
    rows = result.rows();
    const execution_ns = elapsedNanoseconds(execution_start);
    var execution_stats = definition_core.result.ExecutionStats{
        .execution_ns = execution_ns,
        .physical_passes = 1,
        .files_opened = files_opened,
        .bytes_read = bytes_read,
        .rows_scanned = result.source_row_count,
        .rows_materialized = rows_materialized,
        .output_rows = result.row_count,
    };
    const rendered = try renderObservationAlloc(
        allocator,
        .{
            .definition_plan = &context.definition_plan,
            .projection_name = args.projection,
            .parameters_digest = &bindings.values_digest,
            .corpus = .{
                .adapter = corpus_adapter,
                .digest = corpus_digest,
                .files = files_opened,
                .sessions = if (program.source == .physical) 1 else 0,
                .contaminated = false,
            },
            .rows = rows,
            .compile_stats = context.stats,
            .execution_stats = execution_stats,
        },
        &execution_stats,
    );
    defer allocator.free(rendered);
    try writeStdout(rendered);
    try writeStdout("\n");
    return 0;
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

fn parseObserveArgs(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !ObserveArgs {
    var definition_path: ?[]const u8 = null;
    var projection: ?[]const u8 = null;
    var path: ?[]const u8 = null;
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
        if (std.mem.eql(u8, token, "--projection")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (projection != null) return error.DuplicateProjectionOption;
            projection = argv[index];
            continue;
        }
        if (std.mem.eql(u8, token, "--path")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            if (path != null) return error.DuplicatePathOption;
            path = argv[index];
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
        if (std.mem.eql(u8, token, "--format")) {
            index += 1;
            if (index >= argv.len) return error.MissingOptionValue;
            format = try Format.parse(argv[index]);
            continue;
        }
        return error.UnknownOption;
    }
    const input_specs = try inputs.toOwnedSlice(allocator);
    errdefer allocator.free(input_specs);
    return .{
        .definition_path = definition_path orelse
            return error.MissingDefinition,
        .projection = projection orelse return error.MissingProjection,
        .path = path,
        .input_specs = input_specs,
        .parameter_specs = try parameters.toOwnedSlice(allocator),
        .format = format,
    };
}

fn loadDefinition(
    allocator: std.mem.Allocator,
    path: []const u8,
    request: seq.compiled_plan.Request,
) !seq.compiled_plan.PlanSet {
    var location = try definitionLocation(allocator, path);
    defer location.deinit(allocator);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(
        defaultIo(),
        ".",
        allocator,
    );
    defer allocator.free(cwd);
    const cache_dir = try seqCacheDirAlloc(allocator, cwd);
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

fn definitionLocation(
    allocator: std.mem.Allocator,
    path: []const u8,
) !DefinitionLocation {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(
        defaultIo(),
        ".",
        allocator,
    );
    defer allocator.free(cwd);
    const absolute = try std.fs.path.resolve(allocator, &.{ cwd, path });
    defer allocator.free(absolute);
    const within_cwd = pathWithin(absolute, cwd);
    const root = if (within_cwd)
        try allocator.dupe(u8, cwd)
    else
        try allocator.dupe(
            u8,
            std.fs.path.dirname(absolute) orelse
                return error.InvalidDefinitionPath,
        );
    errdefer allocator.free(root);
    const entry = if (within_cwd)
        try allocator.dupe(u8, relativeWithin(absolute, cwd))
    else
        try allocator.dupe(u8, std.fs.path.basename(absolute));
    return .{ .root = root, .entry = entry };
}

fn seqCacheDirAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
) !?[]u8 {
    var base: []const u8 = undefined;
    var suffix: []const u8 = undefined;
    if (environmentValue("SEQ_CACHE_DIR")) |value| {
        base = value;
        suffix = "definitions";
    } else if (environmentValue("XDG_CACHE_HOME")) |value| {
        base = value;
        suffix = "seq/definitions";
    } else if (environmentValue("HOME")) |value| {
        base = value;
        suffix = ".cache/seq/definitions";
    } else {
        return null;
    }
    const joined = try std.fs.path.join(allocator, &.{ base, suffix });
    defer allocator.free(joined);
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
        "{{\"schema\":\"seq-capabilities/v1\",\"version\":\"{s}\",\"observation_abis\":[\"{s}\"],\"source_adapters\":[\"codex-rollout-jsonl/v1\",\"immutable-relation-json/v1\"],\"operators\":[",
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
        "],\"renderers\":[\"json\"],\"cache_format\":{d},\"limits\":{{\"max_output_cells\":{d}}},\"result_schemas\":[\"seq-observation-result/v1\"]}}\n",
        .{ definition_core.cache.format_version, max_output_cells },
    );
    return 0;
}

fn writeCompileStats(
    writer: *std.Io.Writer,
    stats: definition_core.result.CompileStats,
) !void {
    try writer.print(
        "{{\"cache_hit\":{},\"cache_write_failed\":{},\"compile_ns\":{d},\"closure_files\":{d},\"closure_bytes\":{d}}}",
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

fn environmentValue(comptime key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    const bytes = std.mem.span(value);
    return if (bytes.len == 0) null else bytes;
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

test "observe parser accepts only explicit definition inputs and parameters" {
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
    try std.testing.expectEqualStrings("rollout.jsonl", args.path.?);
    try std.testing.expectEqual(@as(usize, 1), args.parameter_specs.len);
}
