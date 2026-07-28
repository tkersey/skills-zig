const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const trace_core = @import("trace_core");
const execution = @import("execution.zig");
const native_plan = @import("plan.zig");
const physical = @import("physical.zig");
const seq_time = @import("seq_time");
const structured = @import("structured.zig");
const trace_adapter = @import("trace_adapter.zig");

const query_output_bytes_max: usize = 16 * 1024 * 1024;

pub const Command = enum {
    sessions,
    turns,
    session_detail,
    tool_lifecycle,
    session_graph,
    tail,
    find_session,
    datasets,
    dataset_schema,
    query,
    index,

    pub fn parse(raw: []const u8) ?Command {
        if (std.mem.eql(u8, raw, "sessions")) return .sessions;
        if (std.mem.eql(u8, raw, "turns")) return .turns;
        if (std.mem.eql(u8, raw, "session-detail")) return .session_detail;
        if (std.mem.eql(u8, raw, "tool-lifecycle")) return .tool_lifecycle;
        if (std.mem.eql(u8, raw, "session-graph")) return .session_graph;
        if (std.mem.eql(u8, raw, "tail")) return .tail;
        if (std.mem.eql(u8, raw, "find-session")) return .find_session;
        if (std.mem.eql(u8, raw, "datasets")) return .datasets;
        if (std.mem.eql(u8, raw, "dataset-schema")) return .dataset_schema;
        if (std.mem.eql(u8, raw, "query")) return .query;
        if (std.mem.eql(u8, raw, "index")) return .index;
        return null;
    }
};

const Format = enum {
    json,
    text,
    dot,

    fn parse(raw: []const u8) !Format {
        if (std.mem.eql(u8, raw, "json")) return .json;
        if (std.mem.eql(u8, raw, "text")) return .text;
        if (std.mem.eql(u8, raw, "dot")) return .dot;
        return error.UnsupportedNativeFormat;
    }
};

pub const Options = struct {
    root: ?[]const u8 = null,
    path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    contains: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    last: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
    status: ?[]const u8 = null,
    dataset: ?[]const u8 = null,
    spec: ?[]const u8 = null,
    action: ?[]const u8 = null,
    current: bool = false,
    once: bool = false,
    limit: usize = 0,
    format: Format = .json,
    environment: ?*const std.process.Environ.Map = null,
};

pub fn run(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    command: Command,
    argv: []const []const u8,
    writer: *std.Io.Writer,
    io: std.Io,
) !u8 {
    var options = try parseOptions(command, argv);
    options.environment = environment;
    const normalized_repo = if (options.repo) |repo|
        try absolutePathAlloc(allocator, options.environment, repo)
    else
        null;
    defer if (normalized_repo) |repo| allocator.free(repo);
    if (normalized_repo) |repo| options.repo = repo;
    switch (command) {
        .sessions => try runRelation(
            allocator,
            writer,
            io,
            .sessions,
            options,
            false,
        ),
        .turns => try runRelation(
            allocator,
            writer,
            io,
            .turns,
            options,
            false,
        ),
        .tool_lifecycle => try runRelation(
            allocator,
            writer,
            io,
            .tool_lifecycle,
            options,
            false,
        ),
        .session_graph => try runSessionGraph(
            allocator,
            writer,
            io,
            options,
        ),
        .session_detail => try runSessionDetail(
            allocator,
            writer,
            io,
            options,
        ),
        .tail => try runTail(allocator, writer, io, options),
        .find_session => try runFindSession(
            allocator,
            writer,
            io,
            options,
        ),
        .datasets => try runDatasets(writer, options),
        .dataset_schema => try runDatasetSchema(writer, options),
        .query => try runQuery(allocator, writer, io, options),
        .index => try runIndex(allocator, writer, io, options),
    }
    return 0;
}

const NativeOption = enum {
    current,
    once,
    root,
    path,
    session_id,
    prompt,
    contains,
    repo,
    since,
    until,
    status,
    dataset,
    spec,
    limit,
    last,
    format,

    fn parse(raw: []const u8) !NativeOption {
        if (std.mem.eql(u8, raw, "--current")) return .current;
        if (std.mem.eql(u8, raw, "--once")) return .once;
        if (std.mem.eql(u8, raw, "--root")) return .root;
        if (std.mem.eql(u8, raw, "--path")) return .path;
        if (std.mem.eql(u8, raw, "--session-id")) return .session_id;
        if (std.mem.eql(u8, raw, "--prompt")) return .prompt;
        if (std.mem.eql(u8, raw, "--contains")) return .contains;
        if (std.mem.eql(u8, raw, "--repo")) return .repo;
        if (std.mem.eql(u8, raw, "--since")) return .since;
        if (std.mem.eql(u8, raw, "--until")) return .until;
        if (std.mem.eql(u8, raw, "--status")) return .status;
        if (std.mem.eql(u8, raw, "--dataset")) return .dataset;
        if (std.mem.eql(u8, raw, "--spec")) return .spec;
        if (std.mem.eql(u8, raw, "--limit")) return .limit;
        if (std.mem.eql(u8, raw, "--last")) return .last;
        if (std.mem.eql(u8, raw, "--format")) return .format;
        return error.UnknownNativeOption;
    }

    fn requiresValue(self: NativeOption) bool {
        return self != .current and self != .once;
    }
};

fn applyNativeOption(
    options: *Options,
    option: NativeOption,
    value: ?[]const u8,
) !void {
    switch (option) {
        .current => {
            if (options.current) return error.DuplicateCurrentSelector;
            options.current = true;
        },
        .once => options.once = true,
        .root => options.root = value.?,
        .path => options.path = value.?,
        .session_id => options.session_id = value.?,
        .prompt => options.prompt = value.?,
        .contains => options.contains = value.?,
        .repo => options.repo = value.?,
        .since => options.since = value.?,
        .until => options.until = value.?,
        .status => options.status = value.?,
        .dataset => options.dataset = value.?,
        .spec => options.spec = value.?,
        .limit => options.limit = try std.fmt.parseUnsigned(
            usize,
            value.?,
            10,
        ),
        .last => options.last = value.?,
        .format => options.format = try Format.parse(value.?),
    }
}

fn validateNativeSelectors(options: *Options) !void {
    if (options.path != null and
        (options.session_id != null or options.current))
    {
        return error.ConflictingSessionSelectors;
    }
    if (options.session_id != null and options.current) {
        return error.ConflictingSessionSelectors;
    }
    try resolveTemporalBounds(options);
}

fn parseOptions(command: Command, argv: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    if (command == .index and argv.len > 0 and
        !std.mem.startsWith(u8, argv[0], "-"))
    {
        options.action = argv[0];
        index = 1;
    }
    while (index < argv.len) : (index += 1) {
        const option = try NativeOption.parse(argv[index]);
        if (!optionAllowed(command, option)) {
            return error.UnsupportedNativeOption;
        }
        const value = if (option.requiresValue())
            try optionValue(argv, &index)
        else
            null;
        try applyNativeOption(&options, option, value);
    }
    try validateNativeSelectors(&options);
    return options;
}

fn optionAllowed(command: Command, option: NativeOption) bool {
    return switch (option) {
        .current, .once => command == .tail,
        .root => switch (command) {
            .sessions,
            .turns,
            .session_detail,
            .tool_lifecycle,
            .session_graph,
            .tail,
            .find_session,
            .query,
            .index,
            => true,
            .datasets, .dataset_schema => false,
        },
        .path => switch (command) {
            .turns,
            .session_detail,
            .tool_lifecycle,
            .session_graph,
            .tail,
            .query,
            => true,
            else => false,
        },
        .session_id => switch (command) {
            .turns,
            .session_detail,
            .tool_lifecycle,
            .session_graph,
            .tail,
            .find_session,
            .query,
            => true,
            else => false,
        },
        .prompt => command == .find_session,
        .contains => command == .sessions or command == .turns,
        .repo => command == .sessions or command == .query,
        .since, .until, .last => switch (command) {
            .sessions, .turns, .find_session, .query => true,
            else => false,
        },
        .status => command == .turns,
        .dataset => command == .dataset_schema,
        .spec => command == .query,
        .limit => switch (command) {
            .sessions,
            .turns,
            .tool_lifecycle,
            .session_graph,
            .tail,
            .find_session,
            => true,
            else => false,
        },
        .format => true,
    };
}

pub fn resolveTemporalBounds(options: *Options) !void {
    if (options.last != null and options.since != null) {
        return error.ConflictingTimeSelectors;
    }
    const until_ms = if (options.until) |raw|
        seq_time.parseIsoTimestampMillis(raw) orelse
            return error.InvalidTimestampSelector
    else
        null;
    options.until_ms = until_ms;
    if (options.last) |raw| {
        const anchor = until_ms orelse currentUnixMillis();
        options.since_ms = std.math.sub(
            i64,
            anchor,
            try parseDurationMillis(raw),
        ) catch return error.InvalidDurationSelector;
        options.until_ms = anchor;
    } else if (options.since) |raw| {
        options.since_ms = seq_time.parseIsoTimestampMillis(raw) orelse
            return error.InvalidTimestampSelector;
    }
    if (options.since_ms != null and options.until_ms != null and
        options.since_ms.? > options.until_ms.?)
    {
        return error.InvalidTemporalWindow;
    }
}

fn parseDurationMillis(raw: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len < 2) return error.InvalidDurationSelector;
    const value = try std.fmt.parseInt(
        i64,
        trimmed[0 .. trimmed.len - 1],
        10,
    );
    if (value <= 0) return error.InvalidDurationSelector;
    const multiplier: i64 = switch (trimmed[trimmed.len - 1]) {
        'm' => 60_000,
        'h' => 3_600_000,
        'd' => 86_400_000,
        else => return error.InvalidDurationSelector,
    };
    return std.math.mul(i64, value, multiplier) catch
        error.InvalidDurationSelector;
}

fn currentUnixMillis() i64 {
    return @intCast(@divFloor(
        std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds,
        1_000_000,
    ));
}

fn optionValue(
    argv: []const []const u8,
    index: *usize,
) ![]const u8 {
    index.* += 1;
    if (index.* >= argv.len) return error.MissingOptionValue;
    return argv[index.*];
}

fn runRelation(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    io: std.Io,
    relation: physical.Relation,
    options: Options,
    require_single: bool,
) !void {
    if (options.format != .json) return error.UnsupportedNativeFormat;
    var paths = try resolveTargetPaths(
        allocator,
        io,
        options,
        require_single,
    );
    defer freePaths(allocator, &paths);

    try writer.writeByte('[');
    var first = true;
    var remaining = options.limit;
    var selection = trace_adapter.RowSelection{
        .remaining = if (options.limit == 0) null else &remaining,
    };
    if (relation == .turns) {
        selection.since_ms = options.since_ms;
        selection.until_ms = options.until_ms;
        selection.status = options.status;
        selection.contains = options.contains;
    }
    for (paths.items) |path| {
        if (selection.remaining != null and remaining == 0) break;
        var trace = if (relation == .sessions)
            try trace_core.parseSessionSummaryTrace(
                allocator,
                path,
                traceOptions(relation),
            )
        else
            try trace_core.parseSessionTrace(
                allocator,
                path,
                traceOptions(relation),
            );
        defer trace.deinit(allocator);
        if (relation == .sessions and
            !sessionPasses(trace.session, options))
        {
            continue;
        }
        _ = try trace_adapter.writeRelationRowsJsonSelected(
            writer,
            &trace,
            relation,
            &first,
            selection,
        );
    }
    try writer.writeAll("]\n");
}

fn runSessionDetail(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    io: std.Io,
    options: Options,
) !void {
    if (options.format != .json) return error.UnsupportedNativeFormat;
    var paths = try resolveTargetPaths(allocator, io, options, true);
    defer freePaths(allocator, &paths);
    var trace = try trace_core.parseSessionTrace(
        allocator,
        paths.items[0],
        traceOptions(.turns),
    );
    defer trace.deinit(allocator);
    try trace_adapter.writeTraceDetailJson(writer, &trace);
    try writer.writeByte('\n');
}

fn runSessionGraph(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    io: std.Io,
    options: Options,
) !void {
    if (options.format == .json) {
        return runRelation(
            allocator,
            writer,
            io,
            .session_edges,
            options,
            false,
        );
    }
    if (options.format != .dot) return error.UnsupportedNativeFormat;
    var paths = try resolveTargetPaths(allocator, io, options, false);
    defer freePaths(allocator, &paths);
    try writer.writeAll("digraph codex_sessions {\n");
    var remaining = options.limit;
    for (paths.items) |path| {
        if (options.limit != 0 and remaining == 0) break;
        var trace = try trace_core.parseSessionTrace(
            allocator,
            path,
            traceOptions(.session_edges),
        );
        defer trace.deinit(allocator);
        for (trace.graph_edges.items) |edge| {
            if (options.limit != 0 and remaining == 0) break;
            const parent = edge.parent_session_id orelse continue;
            const worker = edge.worker_session_id orelse continue;
            try writer.writeAll("  ");
            try definition_core.canonical_json.writeCanonicalString(writer, parent);
            try writer.writeAll(" -> ");
            try definition_core.canonical_json.writeCanonicalString(writer, worker);
            try writer.writeAll(";\n");
            if (options.limit != 0) remaining -= 1;
        }
    }
    try writer.writeAll("}\n");
}

fn runTail(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    io: std.Io,
    options: Options,
) !void {
    if (!options.once) return error.TailFollowRequiresExplicitRuntime;
    return runRelation(
        allocator,
        writer,
        io,
        .source_events,
        options,
        true,
    );
}

fn runFindSession(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    io: std.Io,
    options: Options,
) !void {
    if (options.prompt == null and options.session_id == null) {
        return error.MissingFindSessionSelector;
    }
    if (options.format != .json) return error.UnsupportedNativeFormat;
    var search_options = options;
    search_options.session_id = null;
    var paths = try resolveTargetPaths(
        allocator,
        io,
        search_options,
        false,
    );
    defer freePaths(allocator, &paths);

    try writer.writeByte('[');
    var first = true;
    var remaining = options.limit;
    const selection = trace_adapter.RowSelection{
        .remaining = if (options.limit == 0) null else &remaining,
    };
    for (paths.items) |path| {
        if (selection.remaining != null and remaining == 0) break;
        var trace = try trace_core.parseSessionTrace(
            allocator,
            path,
            traceOptions(.messages),
        );
        defer trace.deinit(allocator);
        if (options.session_id) |wanted| {
            const actual = trace.session.session_id orelse continue;
            if (!std.mem.eql(u8, actual, wanted)) continue;
        }
        if (options.prompt) |needle| {
            if (!traceContainsPrompt(&trace, needle)) continue;
        }
        if (!sessionPasses(trace.session, options)) continue;
        _ = try trace_adapter.writeRelationRowsJsonSelected(
            writer,
            &trace,
            .sessions,
            &first,
            selection,
        );
    }
    try writer.writeAll("]\n");
}

fn runDatasets(writer: *std.Io.Writer, options: Options) !void {
    if (options.format == .text) {
        inline for (@typeInfo(physical.Relation).@"enum".fields) |field| {
            try writer.print("{s}\n", .{field.name});
        }
        return;
    }
    if (options.format != .json) return error.UnsupportedNativeFormat;
    try writer.writeByte('[');
    inline for (@typeInfo(physical.Relation).@"enum".fields, 0..) |field, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"dataset\":");
        try definition_core.canonical_json.writeCanonicalString(writer, field.name);
        try writer.writeAll(",\"description\":\"canonical physical execution relation\"}");
    }
    try writer.writeAll("]\n");
}

fn runDatasetSchema(
    writer: *std.Io.Writer,
    options: Options,
) !void {
    const name = options.dataset orelse return error.MissingDataset;
    const relation = try physical.Relation.parse(name);
    if (options.format == .text) {
        for (relation.fields()) |field| {
            try writer.print(
                "{s}\t{s}\t{s}\n",
                .{
                    field.name,
                    @tagName(field.kind),
                    if (field.nullable) "nullable" else "required",
                },
            );
        }
        return;
    }
    if (options.format != .json) return error.UnsupportedNativeFormat;
    try writer.writeByte('[');
    for (relation.fields(), 0..) |field, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"dataset\":");
        try definition_core.canonical_json.writeCanonicalString(writer, name);
        try writer.writeAll(",\"field\":");
        try definition_core.canonical_json.writeCanonicalString(writer, field.name);
        try writer.print(",\"index\":{d},\"kind\":", .{index});
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            @tagName(field.kind),
        );
        try writer.print(",\"nullable\":{}}}", .{field.nullable});
    }
    try writer.writeAll("]\n");
}

const QueryFormat = enum {
    json,
    jsonl,
};

const QueryCompilation = struct {
    program: execution.Program,
    output_names: [][]const u8,
    relation: physical.Relation,
    format: QueryFormat,

    fn deinit(self: *QueryCompilation, allocator: std.mem.Allocator) void {
        self.program.deinit(allocator);
        allocator.free(self.output_names);
        self.* = undefined;
    }
};

const Demand = struct {
    relation: physical.Relation,
    physical_indices: [256]u16 = undefined,
    count: usize = 0,

    fn add(self: *Demand, name: []const u8) !u16 {
        const physical_index = try self.relation.fieldIndex(name);
        for (self.physical_indices[0..self.count], 0..) |existing, index| {
            if (existing == physical_index) return @intCast(index);
        }
        if (self.count == self.physical_indices.len) {
            return error.PhysicalQueryTooWide;
        }
        self.physical_indices[self.count] = physical_index;
        self.count += 1;
        return @intCast(self.count - 1);
    }
};

fn runQuery(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    io: std.Io,
    options: Options,
) !void {
    const raw_spec = options.spec orelse return error.MissingQuerySpec;
    const spec_bytes = try loadQuerySpecAlloc(allocator, io, raw_spec);
    defer allocator.free(spec_bytes);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        spec_bytes,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidQuerySpec,
    };
    return runQueryObject(allocator, writer, io, options, object);
}

fn runQueryObject(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    io: std.Io,
    options: Options,
    object: std.json.ObjectMap,
) !void {
    const query_options = try queryTargetOptions(options, object);
    var compilation = try compileQuery(allocator, object);
    defer compilation.deinit(allocator);
    if (query_options.format != .json) return error.UnsupportedNativeFormat;

    const output_cells = std.math.mul(
        usize,
        compilation.program.max_rows,
        compilation.program.output_field_indices.len,
    ) catch return error.PhysicalQueryOutputBoundExceeded;
    if (output_cells > 4_000_000) {
        return error.PhysicalQueryOutputBoundExceeded;
    }
    const output = try allocator.alloc(execution.Value, output_cells);
    defer allocator.free(output);
    var runner = try execution.Runner.initOwnedAllocBounded(
        allocator,
        &compilation.program,
        output,
        query_output_bytes_max,
    );
    defer runner.deinit();
    var paths = try resolveTargetPaths(
        allocator,
        io,
        query_options,
        false,
    );
    defer freePaths(allocator, &paths);
    for (paths.items) |path| {
        const feed_result = try feedQueryPath(
            allocator,
            path,
            query_options,
            &compilation,
            &runner,
        );
        if (feed_result == .stop) break;
    }
    const result = try runner.finish();
    try writeQueryRows(
        writer,
        result.rows(),
        compilation.output_names,
        compilation.format,
    );
}

fn feedQueryPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: Options,
    compilation: *const QueryCompilation,
    runner: *execution.Runner,
) !execution.Feed {
    var trace = if (compilation.relation == .sessions)
        try trace_core.parseSessionSummaryTrace(
            allocator,
            path,
            traceOptions(compilation.relation),
        )
    else
        try trace_core.parseSessionTrace(
            allocator,
            path,
            traceOptions(compilation.relation),
        );
    defer trace.deinit(allocator);
    if (compilation.relation == .sessions) {
        if (!sessionPasses(trace.session, options)) {
            return .continue_scanning;
        }
    } else if (!sessionMetadataPasses(trace.session, options)) {
        return .continue_scanning;
    }
    const selection = trace_adapter.RowSelection{
        .since_ms = options.since_ms,
        .until_ms = options.until_ms,
    };
    return switch (compilation.relation) {
        .structured_documents, .structured_values => result: {
            var index = try structured.build(
                allocator,
                &trace,
                compilation.relation == .structured_values,
                .{},
            );
            defer index.deinit(allocator);
            break :result try structured.feedSelected(
                runner,
                &compilation.program,
                &index,
                options.since_ms,
                options.until_ms,
            );
        },
        else => try trace_adapter.feedTraceSelected(
            runner,
            &compilation.program,
            &trace,
            selection,
        ),
    };
}

fn loadQuerySpecAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    raw: []const u8,
) ![]u8 {
    if (raw.len > 1 and raw[0] == '@') {
        return std.Io.Dir.cwd().readFileAlloc(
            io,
            raw[1..],
            allocator,
            .limited(4 * 1024 * 1024),
        );
    }
    if (raw.len > 4 * 1024 * 1024) return error.QuerySpecTooLarge;
    return allocator.dupe(u8, raw);
}

fn queryTargetOptions(
    base: Options,
    object: std.json.ObjectMap,
) !Options {
    var options = base;
    if (object.get("params")) |params_value| {
        const params = switch (params_value) {
            .object => |value| value,
            else => return error.InvalidQueryParams,
        };
        try definition_core.json.requireExactKeys(params, &.{
            "path",
            "session_id",
            "root",
            "repo",
        });
        if (params.get("path")) |value| {
            if (options.path != null) return error.DuplicatePathSelector;
            options.path = try jsonString(value, error.InvalidQueryPath);
        }
        if (params.get("session_id")) |value| {
            if (options.session_id != null) {
                return error.DuplicateSessionSelector;
            }
            options.session_id = try jsonString(
                value,
                error.InvalidQuerySession,
            );
        }
        if (params.get("root")) |value| {
            if (options.root != null) return error.DuplicateRootSelector;
            options.root = try jsonString(value, error.InvalidQueryRoot);
        }
        if (params.get("repo")) |value| {
            if (options.repo != null) return error.DuplicateRepoSelector;
            options.repo = try jsonString(value, error.InvalidQueryRepo);
        }
    }
    if (options.path != null and
        (options.session_id != null or options.current))
    {
        return error.ConflictingSessionSelectors;
    }
    if (options.session_id != null and options.current) {
        return error.ConflictingSessionSelectors;
    }
    return options;
}

fn compileQuery(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !QueryCompilation {
    try definition_core.json.requireExactKeys(object, &.{
        "dataset",
        "select",
        "where",
        "sort",
        "limit",
        "format",
        "params",
    });
    const dataset = try jsonString(
        object.get("dataset") orelse return error.MissingQueryDataset,
        error.InvalidQueryDataset,
    );
    const relation = try physical.Relation.parse(dataset);
    var demand = Demand{ .relation = relation };

    var output_names: std.ArrayList([]const u8) = .empty;
    defer output_names.deinit(allocator);
    var output_fields: std.ArrayList(u16) = .empty;
    defer output_fields.deinit(allocator);
    try appendQueryOutputFields(
        allocator,
        object,
        relation,
        &demand,
        &output_names,
        &output_fields,
    );

    var predicates: std.ArrayList(execution.RuntimePredicate) = .empty;
    defer predicates.deinit(allocator);
    try appendQueryPredicates(allocator, object, &demand, &predicates);

    var sort_keys: std.ArrayList(execution.RuntimeSortKey) = .empty;
    defer sort_keys.deinit(allocator);
    try appendQuerySortKeys(allocator, object, &demand, &sort_keys);

    const limit = if (object.get("limit")) |value|
        try queryLimit(value)
    else
        0;
    const format = if (object.get("format")) |value|
        try queryFormat(try jsonString(value, error.InvalidQueryFormat))
    else
        .json;
    return finishQueryCompilation(
        allocator,
        relation,
        &demand,
        &output_names,
        &output_fields,
        &predicates,
        &sort_keys,
        limit,
        format,
    );
}

fn appendQueryOutputFields(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    relation: physical.Relation,
    demand: *Demand,
    names: *std.ArrayList([]const u8),
    fields: *std.ArrayList(u16),
) !void {
    if (object.get("select")) |select_value| {
        const select = switch (select_value) {
            .array => |value| value,
            else => return error.InvalidQuerySelect,
        };
        if (select.items.len == 0) return error.EmptyQuerySelect;
        for (select.items) |item| {
            const name = try jsonString(item, error.InvalidQuerySelect);
            try names.append(allocator, name);
            try fields.append(allocator, try demand.add(name));
        }
        return;
    }
    for (relation.fields()) |field| {
        try names.append(allocator, field.name);
        try fields.append(allocator, try demand.add(field.name));
    }
}

fn appendQueryPredicates(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    demand: *Demand,
    predicates: *std.ArrayList(execution.RuntimePredicate),
) !void {
    const where_value = object.get("where") orelse return;
    const where = switch (where_value) {
        .array => |value| value,
        else => return error.InvalidQueryWhere,
    };
    if (where.items.len > 128) return error.TooManyQueryPredicates;
    for (where.items) |item| {
        const clause = switch (item) {
            .object => |value| value,
            else => return error.InvalidQueryWhere,
        };
        try definition_core.json.requireExactKeys(clause, &.{
            "field",
            "op",
            "value",
            "case_insensitive",
        });
        const field = try jsonString(
            clause.get("field") orelse return error.MissingQueryField,
            error.InvalidQueryField,
        );
        const operator = try queryPredicateOperator(
            if (clause.get("op")) |value|
                try jsonString(value, error.InvalidQueryOperator)
            else
                "eq",
        );
        const operand = try queryValue(
            clause.get("value") orelse return error.MissingQueryValue,
        );
        const case_insensitive =
            if (clause.get("case_insensitive")) |value|
                try jsonBool(value, error.InvalidQueryCaseFlag)
            else
                false;
        try predicates.append(allocator, .{
            .field_index = try demand.add(field),
            .operator = operator,
            .operand = operand,
            .case_insensitive = case_insensitive,
        });
    }
}

fn appendQuerySortKeys(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    demand: *Demand,
    sort_keys: *std.ArrayList(execution.RuntimeSortKey),
) !void {
    const sort_value = object.get("sort") orelse return;
    const sort = switch (sort_value) {
        .array => |value| value,
        else => return error.InvalidQuerySort,
    };
    if (sort.items.len > 32) return error.TooManyQuerySortKeys;
    for (sort.items) |item| {
        const raw = try jsonString(item, error.InvalidQuerySort);
        if (raw.len == 0) return error.InvalidQuerySort;
        const descending = raw[0] == '-';
        const name = if (descending) raw[1..] else raw;
        if (name.len == 0) return error.InvalidQuerySort;
        try sort_keys.append(allocator, .{
            .field_index = try demand.add(name),
            .direction = if (descending) .descending else .ascending,
            .nulls = .last,
        });
    }
}

const QueryOperations = struct {
    items: []execution.RuntimeOperation,
    first_blocking: ?u16,
    limit_state_count: u16,
    max_rows: usize,
};

fn buildQueryOperations(
    allocator: std.mem.Allocator,
    predicate_count: usize,
    sort_count: usize,
    limit: usize,
) !QueryOperations {
    var operations: std.ArrayList(execution.RuntimeOperation) = .empty;
    defer operations.deinit(allocator);
    if (predicate_count != 0) {
        try operations.append(allocator, .{
            .filter_all = .{ .start = 0, .len = @intCast(predicate_count) },
        });
    }
    var first_blocking: ?u16 = null;
    if (sort_count != 0) {
        first_blocking = @intCast(operations.items.len);
        try operations.append(allocator, .{
            .sort = .{ .start = 0, .len = @intCast(sort_count) },
        });
    }
    if (limit != 0) {
        try operations.append(allocator, .{
            .limit = .{ .count = limit, .state_index = 0 },
        });
    }
    return .{
        .items = try operations.toOwnedSlice(allocator),
        .first_blocking = first_blocking,
        .limit_state_count = if (limit == 0) 0 else 1,
        .max_rows = if (first_blocking == null and limit != 0)
            limit
        else
            100_000,
    };
}

fn finishQueryCompilation(
    allocator: std.mem.Allocator,
    relation: physical.Relation,
    demand: *const Demand,
    output_names: *std.ArrayList([]const u8),
    output_fields: *std.ArrayList(u16),
    predicates: *std.ArrayList(execution.RuntimePredicate),
    sort_keys: *std.ArrayList(execution.RuntimeSortKey),
    limit: usize,
    format: QueryFormat,
) !QueryCompilation {
    const operation_set = try buildQueryOperations(
        allocator,
        predicates.items.len,
        sort_keys.items.len,
        limit,
    );
    errdefer allocator.free(operation_set.items);
    const source_fields = try allocator.dupe(
        u16,
        demand.physical_indices[0..demand.count],
    );
    errdefer allocator.free(source_fields);
    const owned_predicates = try predicates.toOwnedSlice(allocator);
    errdefer allocator.free(owned_predicates);
    const owned_sort_keys = try sort_keys.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sort_keys);
    const distinct_fields = try allocator.alloc(u16, 0);
    errdefer allocator.free(distinct_fields);
    const aggregate_metrics = try allocator.alloc(
        execution.RuntimeAggregateMetric,
        0,
    );
    errdefer allocator.free(aggregate_metrics);
    const owned_output_fields = try output_fields.toOwnedSlice(allocator);
    errdefer allocator.free(owned_output_fields);
    const owned_output_names = try output_names.toOwnedSlice(allocator);
    errdefer allocator.free(owned_output_names);

    return .{
        .program = .{
            .source = .{ .physical = relation },
            .source_width = @intCast(demand.count),
            .source_field_indices = source_fields,
            .source_row_bound = null,
            .operations = operation_set.items,
            .predicates = owned_predicates,
            .sort_keys = owned_sort_keys,
            .distinct_fields = distinct_fields,
            .aggregate_metrics = aggregate_metrics,
            .output_field_indices = owned_output_fields,
            .limit_state_count = operation_set.limit_state_count,
            .first_blocking_operation = operation_set.first_blocking,
            .max_rows = operation_set.max_rows,
        },
        .output_names = owned_output_names,
        .relation = relation,
        .format = format,
    };
}

fn queryPredicateOperator(
    raw: []const u8,
) !native_plan.PredicateOperator {
    if (std.mem.eql(u8, raw, "eq") or
        std.mem.eql(u8, raw, "exact"))
    {
        return .exact;
    }
    if (std.mem.eql(u8, raw, "neq") or
        std.mem.eql(u8, raw, "not-equal"))
    {
        return .not_equal;
    }
    if (std.mem.eql(u8, raw, "contains")) return .contains;
    if (std.mem.eql(u8, raw, "prefix")) return .prefix;
    if (std.mem.eql(u8, raw, "suffix")) return .suffix;
    return error.UnsupportedQueryPredicate;
}

fn queryValue(value: std.json.Value) !execution.Value {
    return switch (value) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .float => |number| if (std.math.isFinite(number))
            .{ .float = number }
        else
            error.InvalidQueryValue,
        .bool => |boolean| .{ .boolean = boolean },
        .null => .null,
        else => error.InvalidQueryValue,
    };
}

fn queryLimit(value: std.json.Value) !usize {
    const number = switch (value) {
        .integer => |integer| integer,
        else => return error.InvalidQueryLimit,
    };
    if (number <= 0 or number > 100_000) return error.InvalidQueryLimit;
    return @intCast(number);
}

fn queryFormat(raw: []const u8) !QueryFormat {
    if (std.mem.eql(u8, raw, "json")) return .json;
    if (std.mem.eql(u8, raw, "jsonl")) return .jsonl;
    return error.InvalidQueryFormat;
}

fn writeQueryRows(
    writer: *std.Io.Writer,
    rows: execution.Rows,
    names: []const []const u8,
    format: QueryFormat,
) !void {
    const count = try rows.count();
    if (format == .json) try writer.writeByte('[');
    for (0..count) |row_index| {
        if (format == .json and row_index != 0) try writer.writeByte(',');
        const row = rows.row(row_index);
        try writer.writeByte('{');
        for (names, row, 0..) |name, value, field_index| {
            if (field_index != 0) try writer.writeByte(',');
            try definition_core.canonical_json.writeCanonicalString(writer, name);
            try writer.writeByte(':');
            try writeQueryValue(writer, value);
        }
        try writer.writeByte('}');
        if (format == .jsonl) try writer.writeByte('\n');
    }
    if (format == .json) try writer.writeAll("]\n");
}

fn writeQueryValue(
    writer: *std.Io.Writer,
    value: execution.Value,
) !void {
    switch (value) {
        .string => |text| {
            try definition_core.canonical_json.writeCanonicalString(writer, text);
        },
        .integer => |number| try writer.print("{d}", .{number}),
        .float => |number| try writer.print("{d}", .{number}),
        .boolean => |boolean| {
            try writer.writeAll(if (boolean) "true" else "false");
        },
        .json => |json| try writer.writeAll(json),
        .null => try writer.writeAll("null"),
    }
}

fn jsonString(value: std.json.Value, err: anyerror) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => err,
    };
}

fn jsonBool(value: std.json.Value, err: anyerror) !bool {
    return switch (value) {
        .bool => |boolean| boolean,
        else => err,
    };
}

fn runIndex(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    io: std.Io,
    options: Options,
) !void {
    if (options.format != .json) return error.UnsupportedNativeFormat;
    const root = try resolveRootAlloc(
        allocator,
        options.environment,
        options.root,
    );
    defer allocator.free(root);
    const index_path = try std.fs.path.join(
        allocator,
        &.{ root, ".seq-index.jsonl" },
    );
    defer allocator.free(index_path);
    const action = options.action orelse "status";
    if (std.mem.eql(u8, action, "build") or
        std.mem.eql(u8, action, "refresh"))
    {
        try writeIndex(allocator, io, root, index_path);
    } else if (std.mem.eql(u8, action, "vacuum")) {
        std.Io.Dir.deleteFileAbsolute(io, index_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    } else if (!std.mem.eql(u8, action, "status")) {
        return error.UnknownIndexAction;
    }
    const exists = indexExists(io, index_path);
    try writer.writeAll("[{\"root\":");
    try definition_core.canonical_json.writeCanonicalString(writer, root);
    try writer.writeAll(",\"index_path\":");
    try definition_core.canonical_json.writeCanonicalString(writer, index_path);
    try writer.print(",\"exists\":{},\"action\":", .{exists});
    try definition_core.canonical_json.writeCanonicalString(writer, action);
    try writer.writeAll("}]\n");
}

fn writeIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    index_path: []const u8,
) !void {
    var paths = try collectJsonlPaths(allocator, io, root);
    defer freePaths(allocator, &paths);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    for (paths.items) |path| {
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        try output.writer.writeAll("{\"path\":");
        try definition_core.canonical_json.writeCanonicalString(
            &output.writer,
            path,
        );
        try output.writer.print(
            ",\"size_bytes\":{d},\"mtime_ns\":{d},\"schema_version\":1,\"parser_version\":1}}\n",
            .{ stat.size, stat.mtime.nanoseconds },
        );
    }
    try durable_store.rejectSymlinkComponents(index_path);
    try durable_store.writeTextAtomic(
        allocator,
        index_path,
        output.written(),
    );
}

fn indexExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

pub fn resolveTargetPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    require_single: bool,
) !std.ArrayList([]u8) {
    if (options.path) |path| {
        var paths: std.ArrayList([]u8) = .empty;
        errdefer freePaths(allocator, &paths);
        try paths.append(
            allocator,
            try absolutePathAlloc(allocator, options.environment, path),
        );
        return paths;
    }
    const root = try resolveRootAlloc(
        allocator,
        options.environment,
        options.root,
    );
    defer allocator.free(root);
    var paths = try collectTargetJsonlPaths(
        allocator,
        io,
        root,
        options,
    );
    errdefer freePaths(allocator, &paths);

    const exact_session_id = options.session_id orelse if (options.current)
        environmentValue(options.environment, "CODEX_THREAD_ID") orelse
            return error.CurrentSessionUnavailable
    else
        null;
    if (exact_session_id) |wanted| {
        retainSessionId(allocator, &paths, wanted);
    }
    if (require_single or exact_session_id != null) {
        if (paths.items.len == 0) return error.SessionNotFound;
        if (paths.items.len != 1) return error.AmbiguousSessionTarget;
    }
    return paths;
}

fn retainSessionId(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]u8),
    wanted: []const u8,
) void {
    var write_index: usize = 0;
    for (paths.items) |path| {
        var trace = trace_core.parseSessionSummaryTrace(
            allocator,
            path,
            traceOptions(.sessions),
        ) catch {
            allocator.free(path);
            continue;
        };
        defer trace.deinit(allocator);
        if (trace.session.session_id != null and
            std.mem.eql(u8, trace.session.session_id.?, wanted))
        {
            paths.items[write_index] = path;
            write_index += 1;
        } else {
            allocator.free(path);
        }
    }
    paths.items.len = write_index;
}

fn collectJsonlPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
) !std.ArrayList([]u8) {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer freePaths(allocator, &paths);
    var root_dir = std.Io.Dir.openDirAbsolute(
        io,
        root,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return paths,
        else => return err,
    };
    defer root_dir.close(io);
    var walker = try root_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;
        if (std.mem.eql(u8, std.fs.path.basename(entry.path), ".seq-index.jsonl")) {
            continue;
        }
        try paths.append(
            allocator,
            try std.fs.path.join(allocator, &.{ root, entry.path }),
        );
    }
    std.mem.sort([]u8, paths.items, {}, lessThanPath);
    return paths;
}

fn collectTargetJsonlPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    _: Options,
) !std.ArrayList([]u8) {
    var paths = try collectJsonlPaths(allocator, io, root);
    errdefer freePaths(allocator, &paths);
    if (paths.items.len > 1_000_000) {
        return error.SessionCandidateBoundExceeded;
    }
    return paths;
}

fn lessThanPath(_: void, left: []u8, right: []u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

pub fn freePaths(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]u8),
) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

fn resolveRootAlloc(
    allocator: std.mem.Allocator,
    environment: ?*const std.process.Environ.Map,
    root: ?[]const u8,
) ![]u8 {
    if (root) |explicit| {
        return absolutePathAlloc(allocator, environment, explicit);
    }
    if (environmentValue(environment, "CODEX_HOME")) |codex_home| {
        return std.fs.path.join(allocator, &.{ codex_home, "sessions" });
    }
    const home = environmentValue(environment, "HOME") orelse
        return error.EnvironmentVariableNotFound;
    return std.fs.path.join(allocator, &.{ home, ".codex", "sessions" });
}

pub fn absolutePathAlloc(
    allocator: std.mem.Allocator,
    environment: ?*const std.process.Environ.Map,
    path: []const u8,
) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = environmentValue(environment, "HOME") orelse
            return error.EnvironmentVariableNotFound;
        return std.fs.path.resolve(allocator, &.{ home, path[2..] });
    }
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        ".",
        allocator,
    );
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

pub fn sessionPasses(
    session: trace_core.SessionRecord,
    options: Options,
) bool {
    const timestamp = session.start_time orelse session.end_time;
    if (options.since_ms) |since| {
        const actual = seq_time.parseIsoTimestampMillis(
            timestamp orelse return false,
        ) orelse return false;
        if (actual < since) return false;
    }
    if (options.until_ms) |until| {
        const actual = seq_time.parseIsoTimestampMillis(
            timestamp orelse return false,
        ) orelse return false;
        if (actual > until) return false;
    }
    return sessionMetadataPasses(session, options);
}

pub fn sessionMetadataPasses(
    session: trace_core.SessionRecord,
    options: Options,
) bool {
    if (options.repo) |repo| {
        const cwd = session.cwd orelse return false;
        if (!pathEqualOrDescendant(cwd, repo)) return false;
    }
    if (options.status) |status| {
        const actual = if (session.is_ongoing) "ongoing" else "complete";
        if (!std.mem.eql(u8, actual, status) and
            !(std.mem.eql(u8, status, "completed") and
                std.mem.eql(u8, actual, "complete")))
        {
            return false;
        }
    }
    if (options.contains) |needle| {
        if (!containsIgnoreCase(session.session_id, needle) and
            !containsIgnoreCase(session.thread_name, needle) and
            !containsIgnoreCase(session.cwd, needle) and
            !containsIgnoreCase(session.git_branch, needle) and
            !containsIgnoreCase(session.model, needle) and
            !containsIgnoreCase(session.path, needle))
        {
            return false;
        }
    }
    return true;
}

fn pathEqualOrDescendant(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (root.len == 0 or std.fs.path.isSep(root[root.len - 1])) return true;
    return path.len > root.len and std.fs.path.isSep(path[root.len]);
}

fn traceContainsPrompt(
    trace: *const trace_core.CanonicalSessionTrace,
    needle: []const u8,
) bool {
    for (trace.turns.items) |turn| {
        if (containsIgnoreCase(turn.user_message, needle) or
            containsIgnoreCase(turn.user_preview, needle))
        {
            return true;
        }
    }
    return false;
}

fn containsIgnoreCase(
    haystack: ?[]const u8,
    needle: []const u8,
) bool {
    const value = haystack orelse return false;
    if (needle.len == 0) return true;
    if (needle.len > value.len) return false;
    var index: usize = 0;
    while (index + needle.len <= value.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(
            value[index .. index + needle.len],
            needle,
        )) return true;
    }
    return false;
}

fn traceOptions(relation: physical.Relation) trace_core.TraceParseOptions {
    return .{
        .include_raw = relation == .source_events,
        .include_occurrences = relation == .source_events or
            relation == .messages or relation == .tool_invocations or
            relation == .tool_results or relation == .structured_documents or
            relation == .structured_values or relation == .token_events,
        .include_token_events = relation == .token_events,
        .include_message_bodies = relation == .turns or
            relation == .messages,
    };
}

fn environmentValue(
    environment: ?*const std.process.Environ.Map,
    key: []const u8,
) ?[]const u8 {
    const map = environment orelse return null;
    const value = map.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

test "relations that expose source event identity retain occurrences" {
    inline for ([_]physical.Relation{
        .source_events,
        .messages,
        .tool_invocations,
        .tool_results,
        .structured_documents,
        .structured_values,
        .token_events,
    }) |relation| {
        try std.testing.expect(traceOptions(relation).include_occurrences);
    }
}

test "final native command registry is physical only" {
    try std.testing.expectEqual(Command.sessions, Command.parse("sessions").?);
    try std.testing.expectEqual(Command.index, Command.parse("index").?);
    try std.testing.expect(Command.parse("skill-audit") == null);
    try std.testing.expect(Command.parse("execution-policy-compile") == null);
}

test "native options reject conflicting session selectors" {
    try std.testing.expectError(
        error.ConflictingSessionSelectors,
        parseOptions(.turns, &.{
            "--path",
            "one.jsonl",
            "--session-id",
            "session",
        }),
    );
}

test "native options reject ignored command modifiers" {
    try std.testing.expectError(
        error.UnsupportedNativeOption,
        parseOptions(.datasets, &.{ "--root", "/tmp/sessions" }),
    );
    try std.testing.expectError(
        error.UnsupportedNativeOption,
        parseOptions(.query, &.{ "--limit", "1" }),
    );
}

test "current session resolves CODEX_THREAD_ID exactly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "current.jsonl",
        .data = testSession("current-session", "2026-07-26T10:00:00Z"),
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "newer.jsonl",
        .data = testSession("newer-session", "2026-07-27T10:00:00Z"),
    });
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("CODEX_THREAD_ID", "current-session");
    var paths = try resolveTargetPaths(
        std.testing.allocator,
        std.testing.io,
        .{
            .root = root,
            .current = true,
            .environment = &environment,
        },
        false,
    );
    defer freePaths(std.testing.allocator, &paths);
    try std.testing.expectEqual(@as(usize, 1), paths.items.len);
    try std.testing.expectEqualStrings(
        "current.jsonl",
        std.fs.path.basename(paths.items[0]),
    );
}

test "exact session selector rejects duplicate corpus matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "one.jsonl",
        .data = testSession("duplicate-session", "2026-07-26T10:00:00Z"),
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "two.jsonl",
        .data = testSession("duplicate-session", "2026-07-27T10:00:00Z"),
    });
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    try std.testing.expectError(
        error.AmbiguousSessionTarget,
        resolveTargetPaths(
            std.testing.allocator,
            std.testing.io,
            .{
                .root = root,
                .session_id = "duplicate-session",
            },
            false,
        ),
    );
}

test "bounded temporal selectors preserve all possible session directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "2026/07/26");
    try tmp.dir.createDirPath(std.testing.io, "2026/07/27");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "2026/07/26/old.jsonl",
        .data = testSession("old-session", "2026-07-26T10:00:00Z"),
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "2026/07/27/current.jsonl",
        .data = testSession("current-session", "2026-07-27T10:00:00Z"),
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "flat.jsonl",
        .data = testSession("flat-session", "2026-07-27T10:00:00Z"),
    });
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    var paths = try resolveTargetPaths(
        std.testing.allocator,
        std.testing.io,
        .{
            .root = root,
            .since_ms = seq_time.parseIsoTimestampMillis(
                "2026-07-27T00:00:00Z",
            ),
            .until_ms = seq_time.parseIsoTimestampMillis(
                "2026-07-27T23:59:59Z",
            ),
        },
        false,
    );
    defer freePaths(std.testing.allocator, &paths);
    try std.testing.expectEqual(@as(usize, 3), paths.items.len);
    try std.testing.expectEqualStrings(
        "old.jsonl",
        std.fs.path.basename(paths.items[0]),
    );
    try std.testing.expectEqualStrings(
        "flat.jsonl",
        std.fs.path.basename(paths.items[2]),
    );
}

test "physical queries select row timestamps across session directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "2026/07/26");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "2026/07/26/rollout.jsonl",
        .data = "{\"timestamp\":\"2026-07-26T23:59:00Z\",\"type\":\"session_meta\"," ++
            "\"payload\":{\"id\":\"multi-day\"}}\n" ++
            "{\"timestamp\":\"2026-07-26T23:59:30Z\",\"type\":\"event_msg\"," ++
            "\"payload\":{\"type\":\"agent_message\",\"message\":\"early\"}}\n" ++
            "{\"timestamp\":\"2026-07-27T00:01:00Z\",\"type\":\"event_msg\"," ++
            "\"payload\":{\"type\":\"agent_message\",\"message\":\"later\"}}\n",
    });
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"dataset\":\"messages\",\"select\":[\"text\",\"timestamp\"]}",
        .{},
    );
    defer parsed.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try runQueryObject(
        std.testing.allocator,
        &output.writer,
        std.testing.io,
        .{
            .root = root,
            .since_ms = seq_time.parseIsoTimestampMillis(
                "2026-07-27T00:00:00Z",
            ),
            .until_ms = seq_time.parseIsoTimestampMillis(
                "2026-07-27T00:02:00Z",
            ),
        },
        parsed.value.object,
    );
    try std.testing.expectEqualStrings(
        "[{\"text\":\"later\",\"timestamp\":\"2026-07-27T00:01:00+00:00\"}]\n",
        output.written(),
    );
}

test "repository selectors require path-component boundaries" {
    const session = trace_core.SessionRecord{
        .path = @constCast("session.jsonl"),
        .cwd = @constCast("/repo/project"),
    };
    try std.testing.expect(sessionPasses(
        session,
        .{ .repo = "/repo" },
    ));
    try std.testing.expect(!sessionPasses(
        session,
        .{ .repo = "/rep" },
    ));
}

fn testSession(
    comptime session_id: []const u8,
    comptime timestamp: []const u8,
) []const u8 {
    return "{\"timestamp\":\"" ++ timestamp ++
        "\",\"type\":\"session_meta\",\"payload\":{\"id\":\"" ++
        session_id ++ "\"}}\n";
}

test "native queries reject unknown spec keys" {
    var top = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"dataset\":\"sessions\",\"selct\":[\"session_id\"]}",
        .{},
    );
    defer top.deinit();
    try std.testing.expectError(
        error.UnknownField,
        compileQuery(std.testing.allocator, top.value.object),
    );

    var params = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"dataset\":\"sessions\",\"params\":{\"rot\":\"sessions\"}}",
        .{},
    );
    defer params.deinit();
    try std.testing.expectError(
        error.UnknownField,
        queryTargetOptions(.{}, params.value.object),
    );

    var clause = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"dataset\":\"sessions\",\"where\":[{\"field\":\"session_id\",\"vaule\":\"x\"}]}",
        .{},
    );
    defer clause.deinit();
    try std.testing.expectError(
        error.UnknownField,
        compileQuery(std.testing.allocator, clause.value.object),
    );
}
