const std = @import("std");
const definition_core = @import("definition_core");
const trace_core = @import("trace_core");
const execution = @import("execution.zig");
const native_plan = @import("plan.zig");
const opencode_adapter = @import("opencode_adapter.zig");
const physical = @import("physical.zig");
const seq_time = @import("seq_time");
const structured = @import("structured.zig");
const trace_adapter = @import("trace_adapter.zig");

const query_output_bytes_max: usize = 16 * 1024 * 1024;
const native_output_bytes_max: usize = 16 * 1024 * 1024;
const native_output_rows_max: usize = 100_000;
const session_candidate_max: usize = 1_000_000;
const session_entry_visit_max: usize = 4_000_000;

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

pub fn help(command: Command) []const u8 {
    return switch (command) {
        .sessions =>
        \\usage: seq sessions [--root <dir>] [--repo <dir>]
        \\  [--contains <text>] [--since <time>] [--until <time>]
        \\  [--last <duration>] [--limit <rows>] [--format json]
        \\
        ,
        .turns =>
        \\usage: seq turns [--root <dir>] [--session-id <id> | --path <file>]
        \\  [--contains <text>] [--status <status>] [--since <time>]
        \\  [--until <time>] [--last <duration>] [--limit <rows>]
        \\  [--format json]
        \\
        ,
        .session_detail =>
        \\usage: seq session-detail [--root <dir>]
        \\  [--session-id <id> | --path <file>] [--format json]
        \\
        ,
        .tool_lifecycle =>
        \\usage: seq tool-lifecycle [--root <dir>]
        \\  [--session-id <id> | --path <file>] [--limit <rows>]
        \\  [--format json]
        \\
        ,
        .session_graph =>
        \\usage: seq session-graph [--root <dir>]
        \\  [--session-id <id> | --path <file>] [--limit <rows>]
        \\  [--format json|dot]
        \\
        ,
        .tail =>
        \\usage: seq tail --once [--root <dir>]
        \\  [--current | --session-id <id> | --path <file>]
        \\  [--limit <rows>] [--format json]
        \\
        ,
        .find_session =>
        \\usage: seq find-session (--prompt <text> | --session-id <id>)
        \\  [--root <dir>] [--since <time>] [--until <time>]
        \\  [--last <duration>] [--limit <rows>] [--format json]
        \\
        ,
        .datasets =>
        \\usage: seq datasets [--format json|text]
        \\
        ,
        .dataset_schema =>
        \\usage: seq dataset-schema --dataset <name> [--format json|text]
        \\
        ,
        .query =>
        \\usage: seq query --spec <json|@file> [--root <dir>]
        \\  [--session-id <id> | --path <file>] [--repo <dir>]
        \\  [--since <time>] [--until <time>] [--last <duration>]
        \\  [--format json]
        \\
        ,
        .index =>
        \\usage: seq index [build|refresh|status] [--root <dir>]
        \\  [--format json]
        \\
        ,
    };
}

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
    limit: usize = native_output_rows_max,
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
    var output_buffer: [8 * 1024]u8 = undefined;
    var bounded = BoundedWriter.init(
        writer,
        native_output_bytes_max,
        &output_buffer,
    );
    runCommand(
        allocator,
        &bounded.interface,
        io,
        command,
        options,
    ) catch |err| {
        if (err == error.WriteFailed and bounded.exceeded) {
            return error.NativeOutputByteBoundExceeded;
        }
        return err;
    };
    bounded.interface.flush() catch |err| {
        if (err == error.WriteFailed and bounded.exceeded) {
            return error.NativeOutputByteBoundExceeded;
        }
        return err;
    };
    return 0;
}

fn runCommand(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    io: std.Io,
    command: Command,
    options: Options,
) !void {
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
}

const BoundedWriter = struct {
    sink: *std.Io.Writer,
    max_bytes: usize,
    bytes_written: usize = 0,
    exceeded: bool = false,
    interface: std.Io.Writer,

    fn init(
        sink: *std.Io.Writer,
        max_bytes: usize,
        buffer: []u8,
    ) BoundedWriter {
        return .{
            .sink = sink,
            .max_bytes = max_bytes,
            .interface = .{
                .vtable = &.{ .drain = drain, .flush = flush },
                .buffer = buffer,
            },
        };
    }

    fn drain(
        interface: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *BoundedWriter = @fieldParentPtr("interface", interface);
        const buffered = interface.buffered();
        var data_count: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            data_count = std.math.add(usize, data_count, bytes.len) catch {
                self.exceeded = true;
                return error.WriteFailed;
            };
        }
        const repeated = std.math.mul(
            usize,
            data[data.len - 1].len,
            splat,
        ) catch {
            self.exceeded = true;
            return error.WriteFailed;
        };
        data_count = std.math.add(usize, data_count, repeated) catch {
            self.exceeded = true;
            return error.WriteFailed;
        };
        const count = std.math.add(
            usize,
            buffered.len,
            data_count,
        ) catch {
            self.exceeded = true;
            return error.WriteFailed;
        };
        if (count > self.max_bytes -| self.bytes_written) {
            self.exceeded = true;
            return error.WriteFailed;
        }
        try self.sink.writeAll(buffered);
        interface.end = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.sink.writeAll(bytes);
        }
        for (0..splat) |_| {
            try self.sink.writeAll(data[data.len - 1]);
        }
        self.bytes_written += count;
        return data_count;
    }

    fn flush(interface: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *BoundedWriter = @fieldParentPtr("interface", interface);
        try interface.defaultFlush();
        try self.sink.flush();
    }
};

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
        .limit => options.limit = try parseNativeLimit(value.?),
        .last => options.last = value.?,
        .format => options.format = try Format.parse(value.?),
    }
}

fn parseNativeLimit(raw: []const u8) !usize {
    const limit = try std.fmt.parseUnsigned(usize, raw, 10);
    if (limit == 0 or limit > native_output_rows_max) {
        return error.InvalidNativeLimit;
    }
    return limit;
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
    var seen_options: u32 = 0;
    var index: usize = 0;
    if (command == .index and argv.len > 0 and
        !std.mem.startsWith(u8, argv[0], "-"))
    {
        options.action = argv[0];
        index = 1;
    }
    while (index < argv.len) : (index += 1) {
        const option = try NativeOption.parse(argv[index]);
        const option_bit = @as(u32, 1) << @intFromEnum(option);
        if (seen_options & option_bit != 0) {
            return error.DuplicateNativeOption;
        }
        seen_options |= option_bit;
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
    const selection = relationRowSelection(options, relation, &remaining);
    for (paths.items) |path| {
        if (selection.remaining != null and remaining == 0) break;
        if (opencode_adapter.recognizes(path)) {
            try writeOpenCodeRelationRows(
                allocator,
                writer,
                relation,
                options,
                path,
                &first,
                &remaining,
            );
            continue;
        }
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
        try rejectTraceWarnings(&trace);
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

fn relationRowSelection(
    options: Options,
    relation: physical.Relation,
    remaining: *usize,
) trace_adapter.RowSelection {
    var selection = trace_adapter.RowSelection{
        .remaining = remaining,
    };
    if (relation == .turns) {
        selection.since_ms = options.since_ms;
        selection.until_ms = options.until_ms;
        selection.status = options.status;
        selection.contains = options.contains;
    }
    return selection;
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
    if (opencode_adapter.recognizes(paths.items[0])) {
        return error.OpenCodeSessionDetailUnavailable;
    }
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
        if (remaining == 0) break;
        var trace = try trace_core.parseSessionTrace(
            allocator,
            path,
            traceOptions(.session_edges),
        );
        defer trace.deinit(allocator);
        for (trace.graph_edges.items) |edge| {
            if (remaining == 0) break;
            const parent = edge.parent_session_id orelse continue;
            const worker = edge.worker_session_id orelse continue;
            try writer.writeAll("  ");
            try definition_core.canonical_json.writeCanonicalString(writer, parent);
            try writer.writeAll(" -> ");
            try definition_core.canonical_json.writeCanonicalString(writer, worker);
            try writer.writeAll(";\n");
            remaining -= 1;
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
    var paths = try resolveTargetPaths(
        allocator,
        io,
        options,
        false,
    );
    defer freePaths(allocator, &paths);

    try writer.writeByte('[');
    var first = true;
    var remaining = options.limit;
    const selection = trace_adapter.RowSelection{
        .remaining = &remaining,
    };
    for (paths.items) |path| {
        if (selection.remaining != null and remaining == 0) break;
        if (opencode_adapter.recognizes(path)) {
            var opencode_options = options;
            opencode_options.contains = options.prompt;
            try writeOpenCodeRelationRows(
                allocator,
                writer,
                .sessions,
                opencode_options,
                path,
                &first,
                &remaining,
            );
            continue;
        }
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
    var query_options = try queryTargetOptions(options, object);
    const normalized_repo = if (query_options.repo) |repo|
        try absolutePathAlloc(allocator, query_options.environment, repo)
    else
        null;
    defer if (normalized_repo) |repo| allocator.free(repo);
    if (normalized_repo) |repo| query_options.repo = repo;
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
    if (opencode_adapter.recognizes(path)) {
        return feedOpenCodeQueryPath(
            allocator,
            path,
            options,
            compilation,
            runner,
        );
    }
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
    try rejectTraceWarnings(&trace);
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

fn feedOpenCodeQueryPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: Options,
    compilation: *const QueryCompilation,
    runner: *execution.Runner,
) !execution.Feed {
    if (options.repo != null or
        options.since_ms != null or
        options.until_ms != null)
    {
        return error.OpenCodePromptHistorySelectorUnavailable;
    }
    if (options.session_id) |wanted| {
        var session_id_buffer: [64]u8 = undefined;
        const session_id = try opencode_adapter.sessionId(
            &session_id_buffer,
            path,
        );
        if (!std.mem.eql(u8, wanted, session_id)) {
            return .continue_scanning;
        }
    }
    const metrics = try opencode_adapter.feedFile(
        allocator,
        &compilation.program,
        runner,
        path,
        256 * 1024 * 1024,
    );
    if (metrics.warnings != 0) return error.PhysicalSourceWarningsPresent;
    return if (runner.stopped) .stop else .continue_scanning;
}

fn rejectTraceWarnings(trace: *const trace_core.CanonicalSessionTrace) !void {
    if (trace.warnings.items.len != 0) {
        return error.PhysicalSourceWarningsPresent;
    }
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
            for (names.items) |prior| {
                if (std.mem.eql(u8, prior, name)) {
                    return error.DuplicateQueryProjection;
                }
            }
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
    const materialized_fields = try allocator.alloc(
        u16,
        if (operation_set.first_blocking == null) 0 else demand.count,
    );
    errdefer allocator.free(materialized_fields);
    for (materialized_fields, 0..) |*field, index| {
        field.* = @intCast(index);
    }
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
            .materialized_field_indices = materialized_fields,
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

fn writeOpenCodeRelationRows(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    relation: physical.Relation,
    options: Options,
    path: []const u8,
    first: *bool,
    remaining: *usize,
) !void {
    if (!try openCodePathPasses(options, path)) return;
    const limit = remaining.*;
    var compilation = try compileAllFieldsQuery(
        allocator,
        relation,
        limit,
    );
    defer compilation.deinit(allocator);
    const output_cells = try std.math.mul(
        usize,
        compilation.program.max_rows,
        compilation.program.output_field_indices.len,
    );
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
    const metrics = try opencode_adapter.feedFileSelected(
        allocator,
        &compilation.program,
        &runner,
        path,
        256 * 1024 * 1024,
        .{
            .status = if (relation == .turns) options.status else null,
            .contains = if (relation == .turns or relation == .sessions)
                options.contains
            else
                null,
        },
    );
    if (metrics.warnings != 0) return error.PhysicalSourceWarningsPresent;
    const result = try runner.finish();
    const rows = result.rows();
    const count = try writeOpenCodeQueryRows(
        writer,
        compilation.output_names,
        rows,
        first,
    );
    remaining.* -|= count;
}

fn openCodePathPasses(options: Options, path: []const u8) !bool {
    if (options.repo != null or
        options.since_ms != null or
        options.until_ms != null)
    {
        return error.OpenCodePromptHistorySelectorUnavailable;
    }
    if (options.session_id) |wanted| {
        var session_id_buffer: [64]u8 = undefined;
        const session_id = try opencode_adapter.sessionId(
            &session_id_buffer,
            path,
        );
        return std.mem.eql(u8, wanted, session_id);
    }
    return true;
}

fn writeOpenCodeQueryRows(
    writer: *std.Io.Writer,
    names: []const []const u8,
    rows: execution.Rows,
    first: *bool,
) !usize {
    const count = try rows.count();
    for (0..count) |row_index| {
        if (!first.*) try writer.writeByte(',');
        first.* = false;
        const row = rows.row(row_index);
        try writer.writeByte('{');
        for (names, row, 0..) |name, value, field_index| {
            if (field_index != 0) try writer.writeByte(',');
            try definition_core.canonical_json.writeCanonicalString(
                writer,
                name,
            );
            try writer.writeByte(':');
            try writeQueryValue(writer, value);
        }
        try writer.writeByte('}');
    }
    return count;
}

fn compileAllFieldsQuery(
    allocator: std.mem.Allocator,
    relation: physical.Relation,
    limit: usize,
) !QueryCompilation {
    var demand = Demand{ .relation = relation };
    var output_names: std.ArrayList([]const u8) = .empty;
    defer output_names.deinit(allocator);
    var output_fields: std.ArrayList(u16) = .empty;
    defer output_fields.deinit(allocator);
    for (relation.fields()) |field| {
        try output_names.append(allocator, field.name);
        try output_fields.append(allocator, try demand.add(field.name));
    }
    var predicates: std.ArrayList(execution.RuntimePredicate) = .empty;
    defer predicates.deinit(allocator);
    var sort_keys: std.ArrayList(execution.RuntimeSortKey) = .empty;
    defer sort_keys.deinit(allocator);
    return finishQueryCompilation(
        allocator,
        relation,
        &demand,
        &output_names,
        &output_fields,
        &predicates,
        &sort_keys,
        limit,
        .json,
    );
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
    const action = options.action orelse "build";
    if (!std.mem.eql(u8, action, "build") and
        !std.mem.eql(u8, action, "refresh") and
        !std.mem.eql(u8, action, "status"))
    {
        return error.UnknownIndexAction;
    }
    var paths = try collectJsonlPaths(
        allocator,
        io,
        root,
        options.root != null,
    );
    defer freePaths(allocator, &paths);
    var total_bytes: u64 = 0;
    var newest_mtime_ns: i128 = 0;
    var files: usize = 0;
    for (paths.items) |path| {
        const stat = std.Io.Dir.cwd().statFile(
            io,
            path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind != .file) continue;
        total_bytes = std.math.add(u64, total_bytes, stat.size) catch
            return error.SessionCorpusByteCountOverflow;
        newest_mtime_ns = @max(newest_mtime_ns, stat.mtime.nanoseconds);
        files += 1;
    }
    try writer.writeAll("{\"schema\":\"seq-index-result/v1\",\"root\":");
    try definition_core.canonical_json.writeCanonicalString(writer, root);
    try writer.writeAll(",\"action\":");
    try definition_core.canonical_json.writeCanonicalString(writer, action);
    try writer.print(
        ",\"files\":{d},\"total_bytes\":{d},\"newest_mtime_ns\":{d}}}\n",
        .{ files, total_bytes, newest_mtime_ns },
    );
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
    const live_native_root = try isLiveNativeSessionRoot(
        allocator,
        options,
        root,
    );
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
    if (exact_session_id == null) {
        retainCanonicalRolloutWindow(
            allocator,
            io,
            &paths,
            options,
            live_native_root,
        );
    }
    if (exact_session_id) |wanted| {
        retainSessionId(allocator, &paths, wanted);
    }
    if (require_single or exact_session_id != null) {
        if (paths.items.len == 0) return error.SessionNotFound;
        if (paths.items.len != 1) return error.AmbiguousSessionTarget;
    }
    return paths;
}

fn retainCanonicalRolloutWindow(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *std.ArrayList([]u8),
    options: Options,
    live_native_root: bool,
) void {
    if (options.since_ms == null and options.until_ms == null) return;
    var write_index: usize = 0;
    for (paths.items) |path| {
        const modified_ms: ?i64 = if (live_native_root and
            options.since_ms != null)
            modifiedMillis(io, path)
        else
            null;
        if (canonicalRolloutPathPassesWindow(
            path,
            options,
            modified_ms,
        )) {
            paths.items[write_index] = path;
            write_index += 1;
        } else {
            allocator.free(path);
        }
    }
    paths.items.len = write_index;
}

fn modifiedMillis(io: std.Io, path: []const u8) ?i64 {
    const stat = std.Io.Dir.cwd().statFile(
        io,
        path,
        .{ .follow_symlinks = false },
    ) catch return null;
    if (stat.kind != .file) return null;
    return std.math.cast(
        i64,
        @divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms),
    );
}

fn canonicalRolloutPathPassesWindow(
    path: []const u8,
    options: Options,
    modified_ms: ?i64,
) bool {
    const basename = std.fs.path.basename(path);
    const prefix = "rollout-";
    if (!std.mem.startsWith(u8, basename, prefix) or
        basename.len < prefix.len + 11 or
        basename[prefix.len + 10] != 'T')
    {
        return true;
    }
    const filename_date = seq_time.parseDayLiteral(
        basename[prefix.len .. prefix.len + 10],
    ) orelse return true;
    const parent = std.fs.path.basename(
        std.fs.path.dirname(path) orelse return true,
    );
    const month_parent = std.fs.path.basename(
        std.fs.path.dirname(
            std.fs.path.dirname(path) orelse return true,
        ) orelse return true,
    );
    const year_parent = std.fs.path.basename(
        std.fs.path.dirname(
            std.fs.path.dirname(
                std.fs.path.dirname(path) orelse return true,
            ) orelse return true,
        ) orelse return true,
    );
    const canonical_parent_date = parsePartitionDate(
        year_parent,
        month_parent,
        parent,
    ) orelse return true;
    if (compareDates(filename_date, canonical_parent_date) != .eq) return true;

    // A canonical partition is a session-start index. On the live native
    // source, filesystem modification time is the append frontier: a resumed
    // session updates it even when its start partition is arbitrarily old.
    // Imported roots do not carry that source guarantee and remain
    // conservative by passing no modification frontier.
    const margin_ms: i64 = 2 * std.time.ms_per_day;
    if (options.since_ms) |since| {
        const lower_ms = std.math.sub(i64, since, margin_ms) catch
            return true;
        const lower = seq_time.dateFromUtcTimestampMillis(lower_ms);
        if (compareDates(filename_date, lower) == .lt) {
            const modified = modified_ms orelse return true;
            if (modified < lower_ms) return false;
        }
    }
    if (options.until_ms) |until| {
        const upper_ms = std.math.add(i64, until, margin_ms) catch
            return true;
        const upper = seq_time.dateFromUtcTimestampMillis(upper_ms);
        if (compareDates(filename_date, upper) == .gt) return false;
    }
    return true;
}

fn parsePartitionDate(
    year: []const u8,
    month: []const u8,
    day: []const u8,
) ?seq_time.Date {
    if (year.len != 4 or month.len != 2 or day.len != 2) return null;
    var text: [10]u8 = undefined;
    @memcpy(text[0..4], year);
    text[4] = '-';
    @memcpy(text[5..7], month);
    text[7] = '-';
    @memcpy(text[8..10], day);
    return seq_time.parseDayLiteral(&text);
}

fn compareDates(left: seq_time.Date, right: seq_time.Date) std.math.Order {
    if (left.year != right.year) return std.math.order(left.year, right.year);
    if (left.month != right.month) {
        return std.math.order(left.month, right.month);
    }
    return std.math.order(left.day, right.day);
}

fn retainSessionId(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]u8),
    wanted: []const u8,
) void {
    var write_index: usize = 0;
    for (paths.items) |path| {
        if (opencode_adapter.recognizes(path)) {
            var session_id_buffer: [64]u8 = undefined;
            const session_id = opencode_adapter.sessionId(
                &session_id_buffer,
                path,
            ) catch {
                allocator.free(path);
                continue;
            };
            if (std.mem.eql(u8, session_id, wanted)) {
                paths.items[write_index] = path;
                write_index += 1;
            } else {
                allocator.free(path);
            }
            continue;
        }
        if (isCanonicalRolloutBasename(std.fs.path.basename(path)) and
            !rolloutBasenameMatchesSessionId(path, wanted))
        {
            allocator.free(path);
            continue;
        }
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

fn isCanonicalRolloutBasename(basename: []const u8) bool {
    return std.mem.startsWith(u8, basename, "rollout-") and
        std.mem.endsWith(u8, basename, ".jsonl");
}

fn rolloutBasenameMatchesSessionId(
    path: []const u8,
    wanted: []const u8,
) bool {
    const basename = std.fs.path.basename(path);
    const extension = ".jsonl";
    if (!isCanonicalRolloutBasename(basename) or
        basename.len < wanted.len + extension.len + 1)
    {
        return false;
    }
    const id_start = basename.len - extension.len - wanted.len;
    return id_start != 0 and basename[id_start - 1] == '-' and
        std.mem.eql(
            u8,
            basename[id_start .. basename.len - extension.len],
            wanted,
        );
}

fn collectJsonlPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    require_existing: bool,
) !std.ArrayList([]u8) {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer freePaths(allocator, &paths);
    var root_dir = std.Io.Dir.openDirAbsolute(
        io,
        root,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            if (require_existing) return error.SessionRootUnavailable;
            return paths;
        },
        else => return err,
    };
    defer root_dir.close(io);
    var walker = try root_dir.walk(allocator);
    defer walker.deinit();
    var visited_entries: usize = 0;
    while (try walker.next(io)) |entry| {
        visited_entries += 1;
        if (visited_entries > session_entry_visit_max) {
            return error.SessionTraversalBoundExceeded;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;
        if (std.mem.eql(u8, std.fs.path.basename(entry.path), ".seq-index.jsonl")) {
            continue;
        }
        if (paths.items.len == session_candidate_max) {
            return error.SessionCandidateBoundExceeded;
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
    options: Options,
) !std.ArrayList([]u8) {
    return collectJsonlPaths(allocator, io, root, options.root != null);
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

fn isLiveNativeSessionRoot(
    allocator: std.mem.Allocator,
    options: Options,
    root: []const u8,
) !bool {
    if (options.root == null) return true;
    const native_root = resolveRootAlloc(
        allocator,
        options.environment,
        null,
    ) catch return false;
    defer allocator.free(native_root);
    return std.mem.eql(u8, root, native_root);
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
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(allocator, &.{path});
    }
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

test "canonical rollout partitions preserve resumed sessions" {
    const options: Options = .{
        .since_ms = seq_time.parseIsoTimestampMillis(
            "2026-07-27T00:00:00Z",
        ),
        .until_ms = seq_time.parseIsoTimestampMillis(
            "2026-07-27T23:59:59Z",
        ),
    };
    try std.testing.expect(canonicalRolloutPathPassesWindow(
        "/sessions/2026/06/01/rollout-2026-06-01T10-00-00-old.jsonl",
        options,
        null,
    ));
    try std.testing.expect(canonicalRolloutPathPassesWindow(
        "/sessions/2026/07/25/rollout-2026-07-25T23-59-59-margin.jsonl",
        options,
        null,
    ));
    try std.testing.expect(canonicalRolloutPathPassesWindow(
        "/sessions/2026/06/01/renamed.jsonl",
        options,
        null,
    ));
    try std.testing.expect(canonicalRolloutPathPassesWindow(
        "/sessions/2026/06/02/rollout-2026-06-01T10-00-00-mismatch.jsonl",
        options,
        null,
    ));
    try std.testing.expect(!canonicalRolloutPathPassesWindow(
        "/sessions/2026/06/01/rollout-2026-06-01T10-00-00-old.jsonl",
        options,
        seq_time.parseIsoTimestampMillis(
            "2026-06-02T00:00:00Z",
        ),
    ));
    try std.testing.expect(canonicalRolloutPathPassesWindow(
        "/sessions/2026/06/01/rollout-2026-06-01T10-00-00-resumed.jsonl",
        options,
        seq_time.parseIsoTimestampMillis(
            "2026-07-27T12:00:00Z",
        ),
    ));
}

test "an explicit canonical session root retains live-source semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".codex/sessions");
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".codex/sessions",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const codex_home = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".codex",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(codex_home);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("CODEX_HOME", codex_home);
    try std.testing.expect(try isLiveNativeSessionRoot(
        std.testing.allocator,
        .{ .root = root, .environment = &environment },
        root,
    ));
    try std.testing.expect(!(try isLiveNativeSessionRoot(
        std.testing.allocator,
        .{ .root = "/tmp/imported", .environment = &environment },
        "/tmp/imported",
    )));
}

test "canonical rollout basenames cut exact session discovery" {
    const wanted = "019c1234-5678-7000-8000-000000000001";
    try std.testing.expect(rolloutBasenameMatchesSessionId(
        "/sessions/2026/07/28/rollout-2026-07-28T12-00-00-" ++
            wanted ++ ".jsonl",
        wanted,
    ));
    try std.testing.expect(!rolloutBasenameMatchesSessionId(
        "/sessions/2026/07/28/rollout-2026-07-28T12-00-00-" ++
            "019c1234-5678-7000-8000-000000000002.jsonl",
        wanted,
    ));
}

test "physical queries select row timestamps across session directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "2026/07/25");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "2026/07/25/rollout-2026-07-25T23-59-00-multi-day.jsonl",
        .data = "{\"timestamp\":\"2026-07-25T23:59:00Z\",\"type\":\"session_meta\"," ++
            "\"payload\":{\"id\":\"multi-day\"}}\n" ++
            "{\"timestamp\":\"2026-07-25T23:59:30Z\",\"type\":\"event_msg\"," ++
            "\"payload\":{\"type\":\"agent_message\",\"message\":\"early\"}}\n" ++
            "{\"timestamp\":\"2026-07-29T00:01:00Z\",\"type\":\"event_msg\"," ++
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
                "2026-07-29T00:00:00Z",
            ),
            .until_ms = seq_time.parseIsoTimestampMillis(
                "2026-07-29T00:02:00Z",
            ),
        },
        parsed.value.object,
    );
    try std.testing.expectEqualStrings(
        "[{\"text\":\"later\",\"timestamp\":\"2026-07-29T00:01:00+00:00\"}]\n",
        output.written(),
    );
}

test "OpenCode native surfaces preserve valid turn numbering and filtering" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "prompt-history.jsonl",
        .data = "{\"input\":\"alpha prompt\",\"mode\":\"build\",\"parts\":[]}\n" ++
            "{\"input\":\"beta needle\",\"mode\":\"ask\",\"parts\":[]}\n",
    });
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "prompt-history.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(path);

    try expectOpenCodeSessionSurfaces(root);
    try expectOpenCodeTurnSurfaces(path);
}

test "OpenCode native surfaces reject malformed source records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "prompt-history.jsonl",
        .data = "{bad-json\n" ++
            "{\"input\":\"valid\",\"mode\":\"build\",\"parts\":[]}\n",
    });
    const path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "prompt-history.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(
        error.PhysicalSourceWarningsPresent,
        runRelation(
            std.testing.allocator,
            &output.writer,
            std.testing.io,
            .turns,
            .{ .path = path },
            true,
        ),
    );
}

fn expectOpenCodeSessionSurfaces(root: []const u8) !void {
    var sessions_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sessions_output.deinit();
    try runRelation(
        std.testing.allocator,
        &sessions_output.writer,
        std.testing.io,
        .sessions,
        .{ .root = root, .contains = "beta" },
        false,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            sessions_output.written(),
            "\"turn_count\":2",
        ) != null,
    );

    var find_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer find_output.deinit();
    try runFindSession(
        std.testing.allocator,
        &find_output.writer,
        std.testing.io,
        .{ .root = root, .prompt = "beta" },
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            find_output.written(),
            "\"turn_count\":2",
        ) != null,
    );
}

fn expectOpenCodeTurnSurfaces(path: []const u8) !void {
    var turns_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer turns_output.deinit();
    try runRelation(
        std.testing.allocator,
        &turns_output.writer,
        std.testing.io,
        .turns,
        .{ .path = path },
        true,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, turns_output.written(), "\"turn_index\":0") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, turns_output.written(), "\"turn_index\":1") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, turns_output.written(), "\"turn_index\":2") == null,
    );

    var detail_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer detail_output.deinit();
    try std.testing.expectError(
        error.OpenCodeSessionDetailUnavailable,
        runSessionDetail(
            std.testing.allocator,
            &detail_output.writer,
            std.testing.io,
            .{ .path = path },
        ),
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

test "absolute repository selectors normalize lexical aliases" {
    const normalized = try absolutePathAlloc(
        std.testing.allocator,
        null,
        "/repo/project/sub/../",
    );
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("/repo/project", normalized);
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

test "native parsing rejects duplicate singleton options and unbounded limits" {
    try std.testing.expectError(
        error.DuplicateNativeOption,
        parseOptions(.sessions, &.{
            "--format",
            "json",
            "--format",
            "json",
        }),
    );
    try std.testing.expectError(
        error.InvalidNativeLimit,
        parseOptions(.sessions, &.{ "--limit", "0" }),
    );
    try std.testing.expectError(
        error.InvalidNativeLimit,
        parseOptions(.sessions, &.{ "--limit", "100001" }),
    );
}

test "native help exposes command-specific required options" {
    try std.testing.expect(
        std.mem.indexOf(u8, help(.query), "--spec") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, help(.dataset_schema), "--dataset") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, help(.tail), "--once") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, help(.find_session), "--prompt") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            help(.index),
            "[build|refresh|status]",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, help(.index), "json|text") == null,
    );
}

test "native output writer fails closed at the aggregate byte bound" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var buffer: [16]u8 = undefined;
    var bounded = BoundedWriter.init(&output.writer, 4, &buffer);
    try bounded.interface.writeAll("1234");
    try bounded.interface.writeByte('5');
    try std.testing.expectError(
        error.WriteFailed,
        bounded.interface.flush(),
    );
    try std.testing.expect(bounded.exceeded);
    try std.testing.expectEqualStrings("", output.written());
}
