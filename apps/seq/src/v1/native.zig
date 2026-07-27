const std = @import("std");
const definition_core = @import("definition_core");
const trace_core = @import("trace_core");
const execution = @import("execution.zig");
const native_plan = @import("plan.zig");
const physical = @import("physical.zig");
const structured = @import("structured.zig");
const trace_adapter = @import("trace_adapter.zig");

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

const Options = struct {
    root: ?[]const u8 = null,
    path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    contains: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    status: ?[]const u8 = null,
    dataset: ?[]const u8 = null,
    spec: ?[]const u8 = null,
    action: ?[]const u8 = null,
    current: bool = false,
    once: bool = false,
    limit: usize = 0,
    format: Format = .json,
};

pub fn run(
    allocator: std.mem.Allocator,
    command: Command,
    argv: []const []const u8,
    writer: *std.Io.Writer,
    io: std.Io,
) !u8 {
    const options = try parseOptions(command, argv);
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

fn parseOptions(
    command: Command,
    argv: []const []const u8,
) !Options {
    var options = Options{};
    var index: usize = 0;
    if (command == .index and argv.len > 0 and
        !std.mem.startsWith(u8, argv[0], "-"))
    {
        options.action = argv[0];
        index = 1;
    }
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (std.mem.eql(u8, token, "--current")) {
            if (options.current) return error.DuplicateCurrentSelector;
            options.current = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--once")) {
            options.once = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--root")) {
            options.root = try optionValue(argv, &index);
            continue;
        }
        if (std.mem.eql(u8, token, "--path")) {
            options.path = try optionValue(argv, &index);
            continue;
        }
        if (std.mem.eql(u8, token, "--session-id")) {
            options.session_id = try optionValue(argv, &index);
            continue;
        }
        if (std.mem.eql(u8, token, "--prompt")) {
            options.prompt = try optionValue(argv, &index);
            continue;
        }
        if (std.mem.eql(u8, token, "--contains")) {
            options.contains = try optionValue(argv, &index);
            continue;
        }
        if (std.mem.eql(u8, token, "--repo")) {
            options.repo = try optionValue(argv, &index);
            continue;
        }
        if (std.mem.eql(u8, token, "--since")) {
            options.since = try optionValue(argv, &index);
            continue;
        }
        if (std.mem.eql(u8, token, "--until")) {
            options.until = try optionValue(argv, &index);
            continue;
        }
        if (std.mem.eql(u8, token, "--status")) {
            options.status = try optionValue(argv, &index);
            continue;
        }
        if (std.mem.eql(u8, token, "--dataset")) {
            options.dataset = try optionValue(argv, &index);
            continue;
        }
        if (std.mem.eql(u8, token, "--spec")) {
            options.spec = try optionValue(argv, &index);
            continue;
        }
        if (std.mem.eql(u8, token, "--limit") or
            std.mem.eql(u8, token, "--last"))
        {
            options.limit = try std.fmt.parseUnsigned(
                usize,
                try optionValue(argv, &index),
                10,
            );
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            options.format = try Format.parse(try optionValue(argv, &index));
            continue;
        }
        return error.UnknownNativeOption;
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
    for (paths.items) |path| {
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
        if (!sessionPasses(trace.session, options)) continue;
        _ = try trace_adapter.writeRelationRowsJson(
            writer,
            &trace,
            relation,
            &first,
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
    for (paths.items) |path| {
        var trace = try trace_core.parseSessionTrace(
            allocator,
            path,
            traceOptions(.session_edges),
        );
        defer trace.deinit(allocator);
        for (trace.graph_edges.items) |edge| {
            const parent = edge.parent_session_id orelse continue;
            const worker = edge.worker_session_id orelse continue;
            try writer.writeAll("  ");
            try definition_core.canonical_json.writeCanonicalString(writer, parent);
            try writer.writeAll(" -> ");
            try definition_core.canonical_json.writeCanonicalString(writer, worker);
            try writer.writeAll(";\n");
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
    for (paths.items) |path| {
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
        _ = try trace_adapter.writeRelationRowsJson(
            writer,
            &trace,
            .sessions,
            &first,
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
    var runner = try execution.Runner.initOwnedAlloc(
        allocator,
        &compilation.program,
        output,
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
        if (!sessionPasses(trace.session, query_options)) continue;
        const feed_result = switch (compilation.relation) {
            .structured_documents, .structured_values => result: {
                var index = try structured.build(
                    allocator,
                    &trace,
                    compilation.relation == .structured_values,
                    .{},
                );
                defer index.deinit(allocator);
                break :result try structured.feed(
                    &runner,
                    &compilation.program,
                    &index,
                );
            },
            else => try trace_adapter.feedTrace(
                &runner,
                &compilation.program,
                &trace,
            ),
        };
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
    if (object.get("select")) |select_value| {
        const select = switch (select_value) {
            .array => |value| value,
            else => return error.InvalidQuerySelect,
        };
        if (select.items.len == 0) return error.EmptyQuerySelect;
        for (select.items) |item| {
            const name = try jsonString(item, error.InvalidQuerySelect);
            try output_names.append(allocator, name);
            try output_fields.append(allocator, try demand.add(name));
        }
    } else {
        for (relation.fields()) |field| {
            try output_names.append(allocator, field.name);
            try output_fields.append(allocator, try demand.add(field.name));
        }
    }

    var predicates: std.ArrayList(execution.RuntimePredicate) = .empty;
    defer predicates.deinit(allocator);
    if (object.get("where")) |where_value| {
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
            const case_insensitive = if (clause.get("case_insensitive")) |value|
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

    var sort_keys: std.ArrayList(execution.RuntimeSortKey) = .empty;
    defer sort_keys.deinit(allocator);
    if (object.get("sort")) |sort_value| {
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

    const limit = if (object.get("limit")) |value|
        try queryLimit(value)
    else
        0;
    const format = if (object.get("format")) |value|
        try queryFormat(try jsonString(value, error.InvalidQueryFormat))
    else
        .json;
    var operations: std.ArrayList(execution.RuntimeOperation) = .empty;
    defer operations.deinit(allocator);
    if (predicates.items.len != 0) {
        try operations.append(allocator, .{
            .filter = .{
                .start = 0,
                .len = @intCast(predicates.items.len),
            },
        });
    }
    var first_blocking_operation: ?u16 = null;
    if (sort_keys.items.len != 0) {
        first_blocking_operation = @intCast(operations.items.len);
        try operations.append(allocator, .{
            .sort = .{
                .start = 0,
                .len = @intCast(sort_keys.items.len),
            },
        });
    }
    if (limit != 0) {
        try operations.append(allocator, .{
            .limit = .{ .count = limit, .state_index = 0 },
        });
    }

    const max_rows: usize = if (first_blocking_operation == null and limit != 0)
        limit
    else
        100_000;
    const source_fields = try allocator.dupe(
        u16,
        demand.physical_indices[0..demand.count],
    );
    errdefer allocator.free(source_fields);
    const owned_operations = try operations.toOwnedSlice(allocator);
    errdefer allocator.free(owned_operations);
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
            .operations = owned_operations,
            .predicates = owned_predicates,
            .sort_keys = owned_sort_keys,
            .distinct_fields = distinct_fields,
            .aggregate_metrics = aggregate_metrics,
            .output_field_indices = owned_output_fields,
            .limit_state_count = if (limit == 0) 0 else 1,
            .first_blocking_operation = first_blocking_operation,
            .max_rows = max_rows,
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
    const root = try resolveRootAlloc(allocator, options.root);
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
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = index_path,
        .data = output.written(),
    });
}

fn indexExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn resolveTargetPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    require_single: bool,
) !std.ArrayList([]u8) {
    if (options.path) |path| {
        var paths: std.ArrayList([]u8) = .empty;
        errdefer freePaths(allocator, &paths);
        try paths.append(allocator, try absolutePathAlloc(allocator, path));
        return paths;
    }
    const root = try resolveRootAlloc(allocator, options.root);
    defer allocator.free(root);
    var paths = try collectJsonlPaths(allocator, io, root);
    errdefer freePaths(allocator, &paths);

    if (options.session_id) |wanted| {
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
    } else if (options.current) {
        try retainCurrentPath(allocator, &paths);
    }
    if (options.limit > 0 and paths.items.len > options.limit) {
        const remove_count = paths.items.len - options.limit;
        for (paths.items[0..remove_count]) |path| allocator.free(path);
        std.mem.copyForwards(
            []u8,
            paths.items[0..options.limit],
            paths.items[remove_count..],
        );
        paths.items.len = options.limit;
    }
    if (require_single) {
        if (paths.items.len == 0) return error.SessionNotFound;
        if (paths.items.len != 1) return error.AmbiguousSessionTarget;
    }
    return paths;
}

fn retainCurrentPath(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]u8),
) !void {
    if (paths.items.len == 0) return;
    var best_index: ?usize = null;
    var best_time: ?[]u8 = null;
    defer if (best_time) |time| allocator.free(time);
    for (paths.items, 0..) |path, index| {
        var trace = trace_core.parseSessionSummaryTrace(
            allocator,
            path,
            traceOptions(.sessions),
        ) catch continue;
        defer trace.deinit(allocator);
        const time = trace.session.start_time orelse
            trace.session.end_time orelse "";
        if (best_index == null or
            std.mem.order(u8, time, best_time.?) == .gt)
        {
            best_index = index;
            if (best_time) |prior| allocator.free(prior);
            best_time = try allocator.dupe(u8, time);
        }
    }
    const keep = best_index orelse return error.SessionNotFound;
    const selected = paths.items[keep];
    for (paths.items, 0..) |path, index| {
        if (index != keep) allocator.free(path);
    }
    paths.items[0] = selected;
    paths.items.len = 1;
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

fn lessThanPath(_: void, left: []u8, right: []u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn freePaths(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]u8),
) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

fn resolveRootAlloc(
    allocator: std.mem.Allocator,
    root: ?[]const u8,
) ![]u8 {
    if (root) |explicit| return absolutePathAlloc(allocator, explicit);
    if (environmentValue("CODEX_HOME")) |codex_home| {
        return std.fs.path.join(allocator, &.{ codex_home, "sessions" });
    }
    const home = environmentValue("HOME") orelse
        return error.EnvironmentVariableNotFound;
    return std.fs.path.join(allocator, &.{ home, ".codex", "sessions" });
}

fn absolutePathAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = environmentValue("HOME") orelse
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

fn sessionPasses(
    session: trace_core.SessionRecord,
    options: Options,
) bool {
    const timestamp = session.start_time orelse session.end_time;
    if (options.since) |since| {
        const actual = timestamp orelse return false;
        if (std.mem.order(u8, actual, since) == .lt) return false;
    }
    if (options.until) |until| {
        const actual = timestamp orelse return false;
        if (std.mem.order(u8, actual, until) != .lt) return false;
    }
    if (options.repo) |repo| {
        const cwd = session.cwd orelse return false;
        if (!std.mem.startsWith(u8, cwd, repo)) return false;
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
            relation == .messages or relation == .token_events,
        .include_token_events = relation == .token_events,
        .include_message_bodies = relation == .turns or
            relation == .messages,
    };
}

fn environmentValue(comptime key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    const bytes = std.mem.span(value);
    return if (bytes.len == 0) null else bytes;
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
