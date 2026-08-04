const std = @import("std");
const definition_core = @import("definition_core");
const trace_core = @import("trace_core");
const definition = @import("definition.zig");
const execution = @import("execution.zig");
const physical = @import("physical.zig");
const plan = @import("plan.zig");
const seq_time = @import("seq_time");
const structured = @import("structured.zig");

pub const Options = struct {
    ongoing_threshold_secs: i64 = 60,
    structured_limits: structured.Limits = .{},
    max_input_bytes: usize = std.math.maxInt(usize),
};

pub const SessionSelection = struct {
    session_id: ?[]const u8 = null,
    exclude_session_id: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
    filter_time: bool = false,
};

pub const SelectedParse = struct {
    parsed: ?ParsedTrace,
    discovery_bytes_read: usize,
    file_opened: bool,
};

pub const SessionIdentity = struct {
    session_id: ?[]u8,
    parent_session_id: ?[]u8,
    bytes_read: usize,
    file_size: usize,

    pub fn deinit(self: *SessionIdentity, allocator: std.mem.Allocator) void {
        if (self.session_id) |value| allocator.free(value);
        if (self.parent_session_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn discoverSessionIdentity(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: Options,
) !SessionIdentity {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try openTraceFile(io, path);
    defer file.close(io);
    const stat = try file.stat(io);
    var file_reader = file.reader(io, &.{});
    const prefix = try readSummaryPrefixAlloc(allocator, &file_reader.interface);
    defer allocator.free(prefix);
    var reader = std.Io.Reader.fixed(prefix);
    var summary = try trace_core.parseSessionSummaryTraceReader(
        allocator,
        path,
        &reader,
        stat.mtime.nanoseconds,
        .{ .ongoing_threshold_secs = options.ongoing_threshold_secs },
    );
    defer summary.deinit(allocator);
    return .{
        .session_id = if (summary.session.session_id) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .parent_session_id = if (summary.session.parent_session_id) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .bytes_read = prefix.len,
        .file_size = std.math.cast(usize, stat.size) orelse
            return error.ObservationInputByteBoundExceeded,
    };
}

pub const Observation = struct {
    trace: trace_core.CanonicalSessionTrace,
    structured_index: structured.Index = .{},
    result: execution.Result,
    metrics: trace_core.StreamMetrics,
    corpus_digest: [71]u8,

    pub fn deinit(self: *Observation, allocator: std.mem.Allocator) void {
        self.structured_index.deinit(allocator);
        self.trace.deinit(allocator);
        self.* = undefined;
    }
};

pub const ParsedTrace = struct {
    trace: trace_core.CanonicalSessionTrace,
    metrics: trace_core.StreamMetrics,
    corpus_digest: [71]u8,

    pub fn deinit(self: *ParsedTrace, allocator: std.mem.Allocator) void {
        self.trace.deinit(allocator);
        self.* = undefined;
    }
};

pub fn parseFile(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    path: []const u8,
    options: Options,
) !ParsedTrace {
    const selected = try parseFileSelected(
        allocator,
        program,
        path,
        options,
        null,
    );
    return selected.parsed orelse unreachable;
}

pub fn parseFileSelected(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    path: []const u8,
    options: Options,
    selection: ?SessionSelection,
) !SelectedParse {
    const relation = switch (program.source) {
        .physical => |value| value,
        .external => return error.ObservationRequiresExternalInput,
    };
    if (!supported(relation)) return error.UnsupportedTracePhysicalRelation;
    if (selection) |selected| {
        if (!canonicalPathPassesSessionSelection(path, selected)) {
            return skippedSelection(false, 0);
        }
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try openTraceFile(io, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > options.max_input_bytes) {
        return error.ObservationInputByteBoundExceeded;
    }
    var file_reader = file.reader(io, &.{});
    const prefix = try readSelectionPrefixAlloc(
        allocator,
        &file_reader.interface,
        selection,
    );
    defer allocator.free(prefix);
    const preselection = if (selection) |selected|
        try preselectSession(
            allocator,
            path,
            stat.mtime.nanoseconds,
            options,
            selected,
            prefix,
        )
    else
        Preselection{};
    if (!preselection.passes) {
        return skippedSelection(true, preselection.bytes_read);
    }
    var replay_reader = PrefixReader.init(
        prefix,
        &file_reader.interface,
    );
    const reader = if (selection != null)
        &replay_reader.interface
    else
        &file_reader.interface;
    return .{
        .parsed = try parseSelectedReader(
            allocator,
            program,
            relation,
            path,
            stat.mtime.nanoseconds,
            reader,
            options,
        ),
        .discovery_bytes_read = 0,
        .file_opened = true,
    };
}

pub fn parseRelationsFileSelected(
    allocator: std.mem.Allocator,
    relations: []const physical.Relation,
    path: []const u8,
    options: Options,
    selection: ?SessionSelection,
) !SelectedParse {
    if (relations.len == 0) return error.EmptyPhysicalRelationSet;
    for (relations) |relation| if (!supported(relation)) {
        return error.UnsupportedTracePhysicalRelation;
    };
    if (selection) |selected| {
        if (!canonicalPathPassesSessionSelection(path, selected)) {
            return skippedSelection(false, 0);
        }
    }
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try openTraceFile(io, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > options.max_input_bytes) {
        return error.ObservationInputByteBoundExceeded;
    }
    var file_reader = file.reader(io, &.{});
    const prefix = try readSelectionPrefixAlloc(
        allocator,
        &file_reader.interface,
        selection,
    );
    defer allocator.free(prefix);
    const preselection = if (selection) |selected|
        try preselectSession(
            allocator,
            path,
            stat.mtime.nanoseconds,
            options,
            selected,
            prefix,
        )
    else
        Preselection{};
    if (!preselection.passes) {
        return skippedSelection(true, preselection.bytes_read);
    }
    var replay_reader = PrefixReader.init(prefix, &file_reader.interface);
    const reader = if (selection != null)
        &replay_reader.interface
    else
        &file_reader.interface;
    var metrics = trace_core.StreamMetrics{};
    var corpus_hasher = CorpusHasher{};
    const trace = try trace_core.parseSessionTraceReaderWithVisitorMetrics(
        allocator,
        path,
        reader,
        stat.mtime.nanoseconds,
        relationParseOptions(relations, options),
        &corpus_hasher,
        CorpusHasher.visit,
        &metrics,
    );
    return .{
        .parsed = .{
            .trace = trace,
            .metrics = metrics,
            .corpus_digest = corpus_hasher.digest(),
        },
        .discovery_bytes_read = 0,
        .file_opened = true,
    };
}

fn relationParseOptions(
    relations: []const physical.Relation,
    options: Options,
) trace_core.TraceParseOptions {
    var result = trace_core.TraceParseOptions{
        .ongoing_threshold_secs = options.ongoing_threshold_secs,
        .include_message_bodies = false,
    };
    for (relations) |relation| {
        result.include_raw = result.include_raw or relation == .source_events;
        result.include_occurrences = result.include_occurrences or
            relation == .source_events or
            relation == .messages or
            relation == .tool_invocations or
            relation == .tool_results or
            relation == .token_events or
            relation == .structured_documents or
            relation == .structured_values;
        result.include_token_events = result.include_token_events or
            relation == .token_events;
        result.include_message_bodies = result.include_message_bodies or
            relation == .turns or relation == .messages;
    }
    result.include_occurrence_payloads = for (relations) |relation| {
        if (relation != .token_events) break true;
    } else false;
    return result;
}

test "token event parsing omits unused occurrence payload copies" {
    const token_options = relationParseOptions(&.{.token_events}, .{});
    try std.testing.expect(token_options.include_occurrences);
    try std.testing.expect(!token_options.include_occurrence_payloads);
    const message_options = relationParseOptions(&.{.messages}, .{});
    try std.testing.expect(message_options.include_occurrence_payloads);
}

fn readSelectionPrefixAlloc(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    selection: ?SessionSelection,
) ![]u8 {
    if (selection != null and requiresSummaryPreselection(selection.?)) {
        return readSummaryPrefixAlloc(allocator, reader);
    }
    return allocator.alloc(u8, 0);
}

fn readSummaryPrefixAlloc(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ![]u8 {
    const max_line_bytes = 256 * 1024 * 1024;
    var prefix: std.ArrayList(u8) = .empty;
    errdefer prefix.deinit(allocator);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) { // tiger: event-loop -- bounded by newline, EOF, or max_line_bytes.
        const read = try reader.readSliceShort(&chunk);
        if (read == 0) break;
        if (read > max_line_bytes -| prefix.items.len) {
            return error.LineTooLong;
        }
        try prefix.appendSlice(allocator, chunk[0..read]);
        if (std.mem.indexOfScalar(u8, chunk[0..read], '\n') != null) break;
    }
    return prefix.toOwnedSlice(allocator);
}

fn openTraceFile(io: std.Io, path: []const u8) !std.Io.File {
    return if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openFile(io, path, .{});
}

fn skippedSelection(file_opened: bool, bytes_read: usize) SelectedParse {
    return .{
        .parsed = null,
        .discovery_bytes_read = bytes_read,
        .file_opened = file_opened,
    };
}

fn parseSelectedReader(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    relation: physical.Relation,
    path: []const u8,
    source_mtime_ns: i128,
    reader: *std.Io.Reader,
    options: Options,
) !ParsedTrace {
    var metrics = trace_core.StreamMetrics{};
    const parse_options = traceParseOptions(
        relation,
        program.source_field_indices,
        options,
    );
    var corpus_hasher = CorpusHasher{};
    const trace = if (relation == .sessions)
        try trace_core.parseSessionSummaryTraceReaderWithVisitorMetrics(
            allocator,
            path,
            reader,
            source_mtime_ns,
            parse_options,
            &corpus_hasher,
            CorpusHasher.visit,
            &metrics,
        )
    else
        try trace_core.parseSessionTraceReaderWithVisitorMetrics(
            allocator,
            path,
            reader,
            source_mtime_ns,
            parse_options,
            &corpus_hasher,
            CorpusHasher.visit,
            &metrics,
        );
    return ParsedTrace{
        .trace = trace,
        .metrics = metrics,
        .corpus_digest = corpus_hasher.digest(),
    };
}

const Preselection = struct {
    passes: bool = true,
    bytes_read: usize = 0,
};

fn canonicalPathPassesSessionSelection(
    path: []const u8,
    selection: SessionSelection,
) bool {
    const basename = std.fs.path.basename(path);
    if (!std.mem.startsWith(u8, basename, "rollout-") or
        !std.mem.endsWith(u8, basename, ".jsonl"))
    {
        return true;
    }
    if (selection.session_id) |wanted| {
        if (canonicalSessionFilenameSuffix(wanted)) |suffix| {
            return std.mem.endsWith(u8, basename, &suffix);
        }
    }
    if (selection.exclude_session_id) |excluded| {
        if (canonicalSessionFilenameSuffix(excluded)) |suffix| {
            if (std.mem.endsWith(u8, basename, &suffix)) return false;
        }
    }
    return true;
}

fn canonicalSessionFilenameSuffix(session_id: []const u8) ?[42]u8 {
    if (!canonicalSessionId(session_id)) return null;
    var suffix: [42]u8 = undefined;
    @memcpy(suffix[0..36], session_id);
    @memcpy(suffix[36..], ".jsonl");
    return suffix;
}

fn canonicalSessionId(session_id: []const u8) bool {
    if (session_id.len != 36) return false;
    for (session_id, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) {
            return false;
        }
    }
    return true;
}

test "canonical rollout paths preselect exact and excluded sessions" {
    const wanted = "019f9cf9-37b3-7692-9bd6-f479dc16e385";
    const other = "019fa6a7-2fe4-7d32-beba-280ecf4e9ff6";
    const wanted_path =
        "/sessions/rollout-2026-07-25T22-50-06-" ++ wanted ++ ".jsonl";
    const other_path =
        "/sessions/rollout-2026-07-27T19-56-42-" ++ other ++ ".jsonl";
    try std.testing.expect(canonicalPathPassesSessionSelection(
        wanted_path,
        .{ .session_id = wanted },
    ));
    try std.testing.expect(!canonicalPathPassesSessionSelection(
        other_path,
        .{ .session_id = wanted },
    ));
    try std.testing.expect(!canonicalPathPassesSessionSelection(
        wanted_path,
        .{ .exclude_session_id = wanted },
    ));
    try std.testing.expect(canonicalPathPassesSessionSelection(
        "renamed.jsonl",
        .{ .session_id = wanted },
    ));
}

fn requiresSummaryPreselection(selection: SessionSelection) bool {
    return selection.session_id != null or
        selection.exclude_session_id != null or
        selection.repo != null or
        selection.filter_time;
}

fn preselectSession(
    allocator: std.mem.Allocator,
    path: []const u8,
    source_mtime_ns: i128,
    options: Options,
    selection: SessionSelection,
    prefix: []const u8,
) !Preselection {
    if (!requiresSummaryPreselection(selection)) {
        return .{};
    }
    var reader = std.Io.Reader.fixed(prefix);
    var summary = try trace_core.parseSessionSummaryTraceReader(
        allocator,
        path,
        &reader,
        source_mtime_ns,
        .{ .ongoing_threshold_secs = options.ongoing_threshold_secs },
    );
    defer summary.deinit(allocator);
    if (selection.session_id) |wanted| {
        if (!exactSessionPasses(summary.session.session_id, wanted)) {
            return .{ .passes = false, .bytes_read = prefix.len };
        }
    }
    if (selection.exclude_session_id) |excluded| {
        if (summary.session.session_id) |actual| {
            if (std.mem.eql(u8, excluded, actual)) {
                return .{ .passes = false, .bytes_read = prefix.len };
            }
        }
    }
    if (selection.repo) |repo| {
        if (summary.session.cwd) |cwd| {
            if (!pathEqualOrDescendant(cwd, repo)) {
                return .{ .passes = false, .bytes_read = prefix.len };
            }
        }
    }
    if (selection.filter_time) {
        const timestamp =
            summary.session.start_time orelse summary.session.end_time;
        if (timestamp) |actual| {
            const actual_ms = seq_time.parseIsoTimestampMillis(actual);
            if ((selection.since_ms != null and
                (actual_ms == null or actual_ms.? < selection.since_ms.?)) or
                (selection.until_ms != null and
                    (actual_ms == null or
                        actual_ms.? > selection.until_ms.?)))
            {
                return .{ .passes = false, .bytes_read = prefix.len };
            }
        }
    }
    return .{ .bytes_read = prefix.len };
}

fn exactSessionPasses(actual: ?[]const u8, wanted: []const u8) bool {
    return actual != null and std.mem.eql(u8, actual.?, wanted);
}

test "exact session selection rejects unidentified traces" {
    try std.testing.expect(!exactSessionPasses(null, "session-wanted"));
    try std.testing.expect(!exactSessionPasses(
        "session-other",
        "session-wanted",
    ));
    try std.testing.expect(exactSessionPasses(
        "session-wanted",
        "session-wanted",
    ));
}

const PrefixReader = struct {
    prefix: []const u8,
    prefix_pos: usize = 0,
    remaining: *std.Io.Reader,
    interface: std.Io.Reader,

    fn init(prefix: []const u8, remaining: *std.Io.Reader) PrefixReader {
        return .{
            .prefix = prefix,
            .remaining = remaining,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *PrefixReader = @fieldParentPtr("interface", reader);
        var written: usize = 0;
        if (self.prefix_pos < self.prefix.len) {
            const available = self.prefix[self.prefix_pos..];
            const selected = limit.sliceConst(available);
            const count = try writer.write(selected);
            self.prefix_pos += count;
            written += count;
            if (count < selected.len or
                written == @intFromEnum(limit))
            {
                return written;
            }
        }
        const remaining_limit = limit.subtract(written) orelse unreachable;
        const count = self.remaining.stream(
            writer,
            remaining_limit,
        ) catch |err| switch (err) {
            error.EndOfStream => if (written == 0)
                return error.EndOfStream
            else
                return written,
            else => return err,
        };
        return written + count;
    }
};

fn pathEqualOrDescendant(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (root.len == 0 or std.fs.path.isSep(root[root.len - 1])) return true;
    return path.len > root.len and std.fs.path.isSep(path[root.len]);
}

pub fn observeFile(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    path: []const u8,
    options: Options,
    output: []execution.Value,
) !Observation {
    const relation = switch (program.source) {
        .physical => |value| value,
        .external => return error.ObservationRequiresExternalInput,
    };
    var parsed = try parseFile(allocator, program, path, options);
    errdefer parsed.deinit(allocator);
    var structured_index = structured.Index{};
    errdefer structured_index.deinit(allocator);
    const observation_result = switch (relation) {
        .structured_documents, .structured_values => structured_result: {
            structured_index = try structured.build(
                allocator,
                &parsed.trace,
                relation == .structured_values,
                options.structured_limits,
            );
            break :structured_result try structured.observe(
                allocator,
                program,
                &structured_index,
                output,
            );
        },
        else => try observeTrace(allocator, program, &parsed.trace, output),
    };

    return .{
        .trace = parsed.trace,
        .structured_index = structured_index,
        .result = observation_result,
        .metrics = parsed.metrics,
        .corpus_digest = parsed.corpus_digest,
    };
}

pub fn observeTrace(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    trace: *const trace_core.CanonicalSessionTrace,
    output: []execution.Value,
) !execution.Result {
    var runner = try execution.Runner.initAlloc(
        allocator,
        program,
        output,
    );
    defer runner.deinit();
    _ = try feedTrace(&runner, program, trace);
    return runner.finish();
}

/// Feeds one immutable canonical trace into a caller-owned compiled runner.
/// This lets directory-level native queries preserve one physical pass per
/// file while applying global blocking operators exactly once.
pub fn feedTrace(
    runner: *execution.Runner,
    program: *const execution.Program,
    trace: *const trace_core.CanonicalSessionTrace,
) !execution.Feed {
    return feedTraceSelected(runner, program, trace, .{});
}

pub fn feedTraceSelected(
    runner: *execution.Runner,
    program: *const execution.Program,
    trace: *const trace_core.CanonicalSessionTrace,
    selection: RowSelection,
) !execution.Feed {
    const relation = switch (program.source) {
        .physical => |value| value,
        .external => return error.ObservationRequiresExternalInput,
    };
    var row_storage: [256]execution.Value = undefined;
    var context = FeedContext{
        .runner = runner,
        .program = program,
        .trace = trace,
        .row = row_storage[0..program.source_width],
        .selection = selection,
    };
    return switch (relation) {
        .sessions, .source_events, .turns, .messages => context.feedPrimary(relation),
        .tool_invocations,
        .tool_results,
        .tool_lifecycle,
        .session_edges,
        => context.feedTools(relation),
        .token_events => context.feedTokenEvents(),
        .structured_documents,
        .structured_values,
        => error.UnsupportedTracePhysicalRelation,
    };
}

const FeedContext = struct {
    runner: *execution.Runner,
    program: *const execution.Program,
    trace: *const trace_core.CanonicalSessionTrace,
    row: []execution.Value,
    selection: RowSelection,

    fn feed(self: *FeedContext) !bool {
        return try self.runner.feed(self.row) == .stop;
    }

    fn result(self: FeedContext) execution.Feed {
        return if (self.runner.stopped) .stop else .continue_scanning;
    }

    fn feedPrimary(
        self: *FeedContext,
        relation: physical.Relation,
    ) !execution.Feed {
        const fields = self.program.source_field_indices;
        switch (relation) {
            .sessions => {
                const timestamp = self.trace.session.start_time orelse
                    self.trace.session.end_time;
                if (!timestampPassesSelection(
                    timestamp,
                    self.selection,
                )) return self.result();
                try fillSession(
                    self.row,
                    fields,
                    self.trace.session,
                );
                _ = try self.feed();
            },
            .source_events => for (self.trace.occurrences.items) |*occurrence| {
                if (!timestampPassesSelection(
                    occurrence.timestamp,
                    self.selection,
                )) continue;
                try fillSourceEvent(
                    self.row,
                    fields,
                    self.trace.session,
                    occurrence,
                );
                if (try self.feed()) break;
            },
            .turns => for (self.trace.turns.items) |turn| {
                if (!turnPassesSelection(turn, self.selection)) continue;
                try fillTurn(self.row, fields, turn);
                if (try self.feed()) break;
            },
            .messages => for (self.trace.occurrences.items) |*occurrence| {
                if (!timestampPassesSelection(
                    occurrence.timestamp,
                    self.selection,
                )) continue;
                if (!occurrence.message_visible or
                    occurrence.role == null or
                    occurrence.text == null)
                {
                    continue;
                }
                try fillMessage(
                    self.row,
                    fields,
                    self.trace.session,
                    occurrence,
                );
                if (try self.feed()) break;
            },
            else => unreachable,
        }
        return self.result();
    }

    fn feedTools(
        self: *FeedContext,
        relation: physical.Relation,
    ) !execution.Feed {
        const fields = self.program.source_field_indices;
        switch (relation) {
            .tool_invocations => for (self.trace.tools.items) |tool| {
                if (tool.declared_line == null) continue;
                if (!timestampPassesSelection(
                    tool.started_at,
                    self.selection,
                )) continue;
                const occurrence = if (containsField(
                    fields,
                    12,
                ))
                    occurrenceAtLine(self.trace, tool.declared_line.?)
                else
                    null;
                try fillToolInvocation(self.row, fields, tool, occurrence);
                if (try self.feed()) break;
            },
            .tool_results => for (self.trace.tools.items) |tool| {
                if (tool.finalized_line == null) continue;
                if (!timestampPassesSelection(
                    tool.completed_at,
                    self.selection,
                )) continue;
                const occurrence = if (containsField(
                    fields,
                    10,
                ))
                    occurrenceAtLine(self.trace, tool.finalized_line.?)
                else
                    null;
                try fillToolResult(self.row, fields, tool, occurrence);
                if (try self.feed()) break;
            },
            .tool_lifecycle => for (self.trace.tools.items) |tool| {
                if (!timestampPassesSelection(
                    tool.started_at orelse tool.completed_at,
                    self.selection,
                )) continue;
                try fillToolLifecycle(self.row, fields, tool);
                if (try self.feed()) break;
            },
            .session_edges => for (self.trace.graph_edges.items) |edge| {
                if (!timestampPassesSelection(
                    edge.spawned_at,
                    self.selection,
                )) continue;
                try fillSessionEdge(self.row, fields, edge);
                if (try self.feed()) break;
            },
            else => unreachable,
        }
        return self.result();
    }

    fn feedTokenEvents(self: *FeedContext) !execution.Feed {
        for (self.trace.token_events.items) |event| {
            if (event.occurrence_index >= self.trace.occurrences.items.len) {
                return error.TokenEventOccurrenceMissing;
            }
            const occurrence =
                &self.trace.occurrences.items[event.occurrence_index];
            if (!timestampPassesSelection(
                occurrence.timestamp,
                self.selection,
            )) continue;
            try fillTokenEvent(
                self.row,
                self.program.source_field_indices,
                self.trace.session,
                occurrence,
                event,
            );
            if (try self.feed()) break;
        }
        return self.result();
    }
};

/// Streams one canonical physical relation as JSON objects without routing
/// through a dynamic row map. `first` is caller-owned so multiple immutable
/// session files can share one output array.
pub fn writeRelationRowsJson(
    writer: *std.Io.Writer,
    trace: *const trace_core.CanonicalSessionTrace,
    relation: physical.Relation,
    first: *bool,
) !usize {
    return writeRelationRowsJsonSelected(
        writer,
        trace,
        relation,
        first,
        .{},
    );
}

pub const RowSelection = struct {
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
    status: ?[]const u8 = null,
    contains: ?[]const u8 = null,
    remaining: ?*usize = null,
};

pub fn writeRelationRowsJsonSelected(
    writer: *std.Io.Writer,
    trace: *const trace_core.CanonicalSessionTrace,
    relation: physical.Relation,
    first: *bool,
    selection: RowSelection,
) !usize {
    if (relation == .structured_documents or
        relation == .structured_values)
    {
        return error.StructuredRelationRequiresIndex;
    }

    const fields = relation.fields();
    var indices: [256]u16 = undefined;
    if (fields.len > indices.len) return error.PhysicalRelationTooWide;
    for (fields, 0..) |_, index| indices[index] = @intCast(index);
    var values: [256]execution.Value = undefined;
    var context = WriteContext{
        .writer = writer,
        .trace = trace,
        .fields = fields,
        .indices = indices[0..fields.len],
        .values = values[0..fields.len],
        .first = first,
        .selection = selection,
    };
    switch (relation) {
        .sessions, .source_events, .turns, .messages => {
            try context.writePrimary(relation);
        },
        .tool_invocations,
        .tool_results,
        .tool_lifecycle,
        .session_edges,
        => try context.writeTools(relation),
        .token_events => try context.writeTokenEvents(),
        .structured_documents, .structured_values => unreachable,
    }
    return context.count;
}

pub fn appendRelationRowsAlloc(
    value_allocator: std.mem.Allocator,
    retained_allocator: std.mem.Allocator,
    interner: *ValueInterner,
    output: *std.ArrayList(execution.Value),
    trace: *const trace_core.CanonicalSessionTrace,
    relation: physical.Relation,
    indices: []const u16,
    selection: RowSelection,
) !usize {
    if (relation == .structured_documents or relation == .structured_values) {
        return error.StructuredRelationRequiresIndex;
    }
    var row_storage: [256]execution.Value = undefined;
    if (indices.len == 0 or indices.len > row_storage.len) {
        return error.PhysicalRelationTooWide;
    }
    var context = CollectContext{
        .value_allocator = value_allocator,
        .retained_allocator = retained_allocator,
        .interner = interner,
        .output = output,
        .trace = trace,
        .indices = indices,
        .values = row_storage[0..indices.len],
        .selection = selection,
    };
    switch (relation) {
        .sessions, .source_events, .turns, .messages => {
            try context.collectPrimary(relation);
        },
        .tool_invocations,
        .tool_results,
        .tool_lifecycle,
        .session_edges,
        => try context.collectTools(relation),
        .token_events => try context.collectTokenEvents(),
        .structured_documents, .structured_values => unreachable,
    }
    return context.count;
}

const CollectContext = struct {
    value_allocator: std.mem.Allocator,
    retained_allocator: std.mem.Allocator,
    interner: *ValueInterner,
    output: *std.ArrayList(execution.Value),
    trace: *const trace_core.CanonicalSessionTrace,
    indices: []const u16,
    values: []execution.Value,
    selection: RowSelection,
    count: usize = 0,

    fn collect(self: *CollectContext) !void {
        for (self.values) |value| {
            try self.output.append(self.value_allocator, try cloneValue(
                self.interner,
                self.value_allocator,
                self.retained_allocator,
                value,
            ));
        }
        self.count += 1;
    }

    fn collectPrimary(
        self: *CollectContext,
        relation: physical.Relation,
    ) !void {
        switch (relation) {
            .sessions => {
                const timestamp = self.trace.session.start_time orelse
                    self.trace.session.end_time;
                if (!timestampPassesSelection(timestamp, self.selection)) return;
                try fillSession(self.values, self.indices, self.trace.session);
                try self.collect();
            },
            .source_events => for (self.trace.occurrences.items) |*occurrence| {
                if (!timestampPassesSelection(occurrence.timestamp, self.selection)) continue;
                try fillSourceEvent(
                    self.values,
                    self.indices,
                    self.trace.session,
                    occurrence,
                );
                try self.collect();
            },
            .turns => for (self.trace.turns.items) |turn| {
                if (!turnPassesSelection(turn, self.selection)) continue;
                try fillTurn(self.values, self.indices, turn);
                try self.collect();
            },
            .messages => for (self.trace.occurrences.items) |*occurrence| {
                if (!timestampPassesSelection(occurrence.timestamp, self.selection)) continue;
                if (!occurrence.message_visible or occurrence.role == null or
                    occurrence.text == null) continue;
                try fillMessage(
                    self.values,
                    self.indices,
                    self.trace.session,
                    occurrence,
                );
                try self.collect();
            },
            else => unreachable,
        }
    }

    fn collectTools(
        self: *CollectContext,
        relation: physical.Relation,
    ) !void {
        switch (relation) {
            .tool_invocations => for (self.trace.tools.items) |tool| {
                if (tool.declared_line == null or
                    !timestampPassesSelection(tool.started_at, self.selection)) continue;
                try fillToolInvocation(
                    self.values,
                    self.indices,
                    tool,
                    occurrenceAtLine(self.trace, tool.declared_line.?),
                );
                try self.collect();
            },
            .tool_results => for (self.trace.tools.items) |tool| {
                if (tool.finalized_line == null or
                    !timestampPassesSelection(tool.completed_at, self.selection)) continue;
                try fillToolResult(
                    self.values,
                    self.indices,
                    tool,
                    occurrenceAtLine(self.trace, tool.finalized_line.?),
                );
                try self.collect();
            },
            .tool_lifecycle => for (self.trace.tools.items) |tool| {
                if (!timestampPassesSelection(
                    tool.started_at orelse tool.completed_at,
                    self.selection,
                )) continue;
                try fillToolLifecycle(self.values, self.indices, tool);
                try self.collect();
            },
            .session_edges => for (self.trace.graph_edges.items) |edge| {
                if (!timestampPassesSelection(edge.spawned_at, self.selection)) continue;
                try fillSessionEdge(self.values, self.indices, edge);
                try self.collect();
            },
            else => unreachable,
        }
    }

    fn collectTokenEvents(self: *CollectContext) !void {
        for (self.trace.token_events.items) |event| {
            if (event.occurrence_index >= self.trace.occurrences.items.len) {
                return error.TokenEventOccurrenceMissing;
            }
            const occurrence = &self.trace.occurrences.items[event.occurrence_index];
            if (!timestampPassesSelection(occurrence.timestamp, self.selection)) continue;
            try fillTokenEvent(
                self.values,
                self.indices,
                self.trace.session,
                occurrence,
                event,
            );
            try self.collect();
        }
    }
};

fn cloneValue(
    interner: *ValueInterner,
    map_allocator: std.mem.Allocator,
    retained_allocator: std.mem.Allocator,
    value: execution.Value,
) !execution.Value {
    return switch (value) {
        .string => |text| .{ .string = try interner.intern(map_allocator, retained_allocator, text) },
        .json => |text| .{ .json = try interner.intern(map_allocator, retained_allocator, text) },
        else => value,
    };
}

pub const ValueInterner = struct {
    values: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn deinit(self: *ValueInterner, allocator: std.mem.Allocator) void {
        self.values.deinit(allocator);
        self.* = undefined;
    }

    fn intern(
        self: *ValueInterner,
        map_allocator: std.mem.Allocator,
        retained_allocator: std.mem.Allocator,
        text: []const u8,
    ) ![]const u8 {
        if (self.values.get(text)) |value| return value;
        const retained = try retained_allocator.dupe(u8, text);
        const entry = try self.values.getOrPut(map_allocator, retained);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = retained;
        return retained;
    }
};

const WriteContext = struct {
    writer: *std.Io.Writer,
    trace: *const trace_core.CanonicalSessionTrace,
    fields: []const physical.Field,
    indices: []const u16,
    values: []execution.Value,
    first: *bool,
    selection: RowSelection,
    count: usize = 0,

    fn exhausted(self: WriteContext) bool {
        return if (self.selection.remaining) |remaining|
            remaining.* == 0
        else
            false;
    }

    fn write(self: *WriteContext) !bool {
        if (self.exhausted()) return false;
        try writePhysicalRowJson(
            self.writer,
            self.fields,
            self.values,
            self.first,
        );
        self.count += 1;
        if (self.selection.remaining) |remaining| remaining.* -= 1;
        return true;
    }

    fn writePrimary(
        self: *WriteContext,
        relation: physical.Relation,
    ) !void {
        switch (relation) {
            .sessions => {
                const timestamp = self.trace.session.start_time orelse
                    self.trace.session.end_time;
                if (!timestampPassesSelection(
                    timestamp,
                    self.selection,
                )) return;
                try fillSession(self.values, self.indices, self.trace.session);
                _ = try self.write();
            },
            .source_events => for (self.trace.occurrences.items) |*occurrence| {
                if (self.exhausted()) break;
                if (!timestampPassesSelection(
                    occurrence.timestamp,
                    self.selection,
                )) continue;
                try fillSourceEvent(
                    self.values,
                    self.indices,
                    self.trace.session,
                    occurrence,
                );
                _ = try self.write();
            },
            .turns => for (self.trace.turns.items) |turn| {
                if (!turnPassesSelection(turn, self.selection)) continue;
                try fillTurn(self.values, self.indices, turn);
                if (!try self.write()) break;
            },
            .messages => for (self.trace.occurrences.items) |*occurrence| {
                if (self.exhausted()) break;
                if (!timestampPassesSelection(
                    occurrence.timestamp,
                    self.selection,
                )) continue;
                if (!occurrence.message_visible or
                    occurrence.role == null or
                    occurrence.text == null)
                {
                    continue;
                }
                try fillMessage(
                    self.values,
                    self.indices,
                    self.trace.session,
                    occurrence,
                );
                _ = try self.write();
            },
            else => unreachable,
        }
    }

    fn writeTools(
        self: *WriteContext,
        relation: physical.Relation,
    ) !void {
        switch (relation) {
            .tool_invocations => for (self.trace.tools.items) |tool| {
                if (self.exhausted()) break;
                if (tool.declared_line == null) continue;
                if (!timestampPassesSelection(
                    tool.started_at,
                    self.selection,
                )) continue;
                try fillToolInvocation(
                    self.values,
                    self.indices,
                    tool,
                    occurrenceAtLine(self.trace, tool.declared_line.?),
                );
                _ = try self.write();
            },
            .tool_results => for (self.trace.tools.items) |tool| {
                if (self.exhausted()) break;
                if (tool.finalized_line == null) continue;
                if (!timestampPassesSelection(
                    tool.completed_at,
                    self.selection,
                )) continue;
                try fillToolResult(
                    self.values,
                    self.indices,
                    tool,
                    occurrenceAtLine(self.trace, tool.finalized_line.?),
                );
                _ = try self.write();
            },
            .tool_lifecycle => for (self.trace.tools.items) |tool| {
                if (self.exhausted()) break;
                if (!timestampPassesSelection(
                    tool.started_at orelse tool.completed_at,
                    self.selection,
                )) continue;
                try fillToolLifecycle(self.values, self.indices, tool);
                _ = try self.write();
            },
            .session_edges => for (self.trace.graph_edges.items) |edge| {
                if (self.exhausted()) break;
                if (!timestampPassesSelection(
                    edge.spawned_at,
                    self.selection,
                )) continue;
                try fillSessionEdge(self.values, self.indices, edge);
                _ = try self.write();
            },
            else => unreachable,
        }
    }

    fn writeTokenEvents(self: *WriteContext) !void {
        for (self.trace.token_events.items) |event| {
            if (self.exhausted()) break;
            if (event.occurrence_index >= self.trace.occurrences.items.len) {
                return error.TokenEventOccurrenceMissing;
            }
            const occurrence =
                &self.trace.occurrences.items[event.occurrence_index];
            if (!timestampPassesSelection(
                occurrence.timestamp,
                self.selection,
            )) continue;
            try fillTokenEvent(
                self.values,
                self.indices,
                self.trace.session,
                occurrence,
                event,
            );
            _ = try self.write();
        }
    }
};

fn turnPassesSelection(
    turn: trace_core.TurnRecord,
    selection: RowSelection,
) bool {
    const timestamp = turn.started_at orelse turn.completed_at;
    if (!timestampPassesSelection(timestamp, selection)) return false;
    if (selection.status) |status| {
        if (!std.mem.eql(u8, @tagName(turn.status), status)) return false;
    }
    if (selection.contains) |needle| {
        if (!containsIgnoreCase(turn.user_message, needle) and
            !containsIgnoreCase(turn.user_preview, needle) and
            !containsIgnoreCase(turn.final_answer, needle) and
            !containsIgnoreCase(turn.assistant_preview, needle) and
            !containsIgnoreCase(turn.model, needle) and
            !containsIgnoreCase(turn.path, needle))
        {
            return false;
        }
    }
    return true;
}

fn timestampPassesSelection(
    timestamp: ?[]const u8,
    selection: RowSelection,
) bool {
    if (selection.since_ms) |since| {
        const actual = seq_time.parseIsoTimestampMillis(
            timestamp orelse return false,
        ) orelse return false;
        if (actual < since) return false;
    }
    if (selection.until_ms) |until| {
        const actual = seq_time.parseIsoTimestampMillis(
            timestamp orelse return false,
        ) orelse return false;
        if (actual > until) return false;
    }
    return true;
}

fn containsIgnoreCase(
    haystack: ?[]const u8,
    needle: []const u8,
) bool {
    const text = haystack orelse return false;
    if (needle.len == 0) return true;
    if (text.len < needle.len) return false;
    for (0..text.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(
            text[index .. index + needle.len],
            needle,
        )) return true;
    }
    return false;
}

pub fn writeTraceDetailJson(
    writer: *std.Io.Writer,
    trace: *const trace_core.CanonicalSessionTrace,
) !void {
    try writer.writeAll("{\"session\":");
    var first = true;
    _ = try writeRelationRowsJson(writer, trace, .sessions, &first);

    try writer.writeAll(",\"turns\":[");
    first = true;
    _ = try writeRelationRowsJson(writer, trace, .turns, &first);
    try writer.writeAll("],\"tools\":[");
    first = true;
    _ = try writeRelationRowsJson(writer, trace, .tool_lifecycle, &first);
    try writer.writeAll("],\"graph_edges\":[");
    first = true;
    _ = try writeRelationRowsJson(writer, trace, .session_edges, &first);
    try writer.writeAll("],\"warnings\":[");
    for (trace.warnings.items, 0..) |warning, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(writer, warning);
    }
    try writer.writeAll("],\"authority_granted\":false}");
}

fn writePhysicalRowJson(
    writer: *std.Io.Writer,
    fields: []const physical.Field,
    values: []const execution.Value,
    first: *bool,
) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writer.writeByte('{');
    for (fields, values, 0..) |field, value, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(writer, field.name);
        try writer.writeByte(':');
        try writePhysicalValueJson(writer, value);
    }
    try writer.writeByte('}');
}

fn writePhysicalValueJson(
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

fn supported(relation: physical.Relation) bool {
    return switch (relation) {
        .sessions,
        .source_events,
        .turns,
        .messages,
        .tool_invocations,
        .tool_results,
        .tool_lifecycle,
        .session_edges,
        .token_events,
        .structured_documents,
        .structured_values,
        => true,
    };
}

fn traceParseOptions(
    relation: physical.Relation,
    demanded_fields: []const u16,
    options: Options,
) trace_core.TraceParseOptions {
    return .{
        .ongoing_threshold_secs = options.ongoing_threshold_secs,
        .include_raw = relation == .source_events and
            containsField(demanded_fields, 8),
        .include_occurrences = relation == .source_events or
            relation == .messages or
            relation == .token_events or
            (relation == .tool_invocations and
                containsField(demanded_fields, 12)) or
            (relation == .tool_results and
                containsField(demanded_fields, 10)) or
            relation == .structured_documents or
            relation == .structured_values,
        .include_token_events = relation == .token_events,
        .include_message_bodies = relation == .turns and
            (containsField(demanded_fields, 9) or
                containsField(demanded_fields, 10)),
    };
}

fn containsField(fields: []const u16, wanted: u16) bool {
    for (fields) |field| if (field == wanted) return true;
    return false;
}

const CorpusHasher = struct {
    hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),

    fn visit(self: *CorpusHasher, line: []const u8, _: usize) !void {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(line.len), .big);
        self.hasher.update(&length);
        self.hasher.update(line);
    }

    fn digest(self: CorpusHasher) [71]u8 {
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

fn fillSourceEvent(
    row: []execution.Value,
    fields: []const u16,
    session: trace_core.SessionRecord,
    occurrence: *const trace_core.TraceOccurrence,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => .{ .string = occurrence.sourceEventId() },
            1 => optionalString(session.session_id),
            2 => .{ .string = session.path },
            3 => try usizeInteger(occurrence.line_number),
            4 => .{ .string = occurrence.entry_type },
            5 => optionalString(occurrence.event_type),
            6 => optionalString(occurrence.timestamp),
            7 => optionalJson(occurrence.payload_json),
            8 => optionalJson(occurrence.raw_json),
            9 => .{ .string = @tagName(occurrence.format) },
            10 => optionalInteger(occurrence.turn_index),
            11 => optionalString(occurrence.role),
            12 => optionalString(occurrence.text),
            13 => .{ .boolean = occurrence.private },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillSession(
    row: []execution.Value,
    fields: []const u16,
    session: trace_core.SessionRecord,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(session.session_id),
            1 => .{ .string = session.path },
            2 => optionalString(session.start_time),
            3 => optionalString(session.end_time),
            4 => optionalString(session.cwd),
            5 => optionalString(session.git_branch),
            6 => optionalString(session.git_commit_hash),
            7 => optionalString(session.git_repository_url),
            8 => optionalString(session.originator),
            9 => optionalString(session.cli_version),
            10 => optionalString(session.model),
            11 => optionalString(session.model_provider),
            12 => optionalString(session.thread_name),
            13 => .{ .integer = session.turn_count },
            14 => optionalInteger(session.total_tokens),
            15 => optionalInteger(session.input_tokens),
            16 => optionalInteger(session.cached_input_tokens),
            17 => optionalInteger(session.output_tokens),
            18 => optionalInteger(session.reasoning_output_tokens),
            19 => .{ .boolean = session.is_ongoing },
            20 => optionalString(session.status_reason),
            21 => .{ .boolean = session.is_external_worker },
            22 => .{ .boolean = session.is_inline_worker },
            23 => .{ .integer = session.spawned_worker_count },
            24 => optionalString(session.root_session_id),
            25 => optionalString(session.parent_session_id),
            26 => optionalString(session.parent_relation),
            27 => .{ .boolean = session.lineage_conflict },
            28 => optionalString(session.service_tier),
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillMessage(
    row: []execution.Value,
    fields: []const u16,
    session: trace_core.SessionRecord,
    occurrence: *const trace_core.TraceOccurrence,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => .{ .string = occurrence.sourceEventId() },
            1 => optionalString(session.session_id),
            2 => optionalInteger(occurrence.turn_index),
            3 => optionalString(occurrence.role),
            4 => optionalString(occurrence.text),
            5 => optionalString(occurrence.timestamp),
            6 => .{ .string = occurrence.sourceEventId() },
            7 => .{ .string = session.path },
            8 => .{ .boolean = occurrence.private },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillTurn(
    row: []execution.Value,
    fields: []const u16,
    turn: trace_core.TurnRecord,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(turn.session_id),
            1 => .{ .string = turn.path },
            2 => .{ .string = turn.turn_id },
            3 => .{ .integer = turn.turn_index },
            4 => optionalString(turn.started_at),
            5 => optionalString(turn.completed_at),
            6 => optionalInteger(turn.duration_ms),
            7 => .{ .string = @tagName(turn.status) },
            8 => optionalString(turn.status_reason),
            9 => optionalString(turn.user_message),
            10 => optionalString(turn.final_answer),
            11 => optionalString(turn.model),
            12 => optionalString(turn.cwd),
            13 => optionalString(turn.reasoning_effort),
            14 => optionalInteger(turn.input_tokens),
            15 => optionalInteger(turn.cached_input_tokens),
            16 => optionalInteger(turn.output_tokens),
            17 => optionalInteger(turn.reasoning_output_tokens),
            18 => optionalInteger(turn.total_tokens),
            19 => .{ .integer = turn.tool_count },
            20 => .{ .boolean = turn.has_compaction },
            21 => optionalString(turn.thread_name),
            22 => optionalString(turn.@"error"),
            23 => optionalString(turn.aborted_reason),
            24 => .{ .integer = turn.spawned_worker_count },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillToolInvocation(
    row: []execution.Value,
    fields: []const u16,
    tool: trace_core.ToolLifecycleRecord,
    occurrence: ?*const trace_core.TraceOccurrence,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(tool.call_id),
            1 => optionalString(tool.session_id),
            2 => optionalString(tool.turn_id),
            3 => optionalInteger(tool.turn_index),
            4 => optionalString(tool.started_at),
            5 => .{ .string = @tagName(tool.kind) },
            6 => optionalString(tool.tool_name),
            7 => optionalString(tool.namespace),
            8 => optionalJson(tool.arguments_json),
            9 => optionalString(tool.input_text),
            10 => optionalString(tool.command_text),
            11 => optionalString(tool.cwd),
            12 => if (occurrence) |value|
                .{ .string = value.sourceEventId() }
            else
                .null,
            13 => .{ .string = tool.path },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillToolResult(
    row: []execution.Value,
    fields: []const u16,
    tool: trace_core.ToolLifecycleRecord,
    occurrence: ?*const trace_core.TraceOccurrence,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(tool.call_id),
            1 => optionalString(tool.session_id),
            2 => optionalString(tool.turn_id),
            3 => optionalInteger(tool.turn_index),
            4 => optionalString(tool.completed_at),
            5 => optionalString(tool.output_text),
            6 => optionalInteger(tool.exit_code),
            7 => optionalInteger(tool.duration_ms),
            8 => optionalBoolean(tool.patch_success),
            9 => optionalJson(tool.patch_changes_json),
            10 => if (occurrence) |value|
                .{ .string = value.sourceEventId() }
            else
                .null,
            11 => .{ .string = tool.path },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillToolLifecycle(
    row: []execution.Value,
    fields: []const u16,
    tool: trace_core.ToolLifecycleRecord,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(tool.call_id),
            1 => optionalString(tool.session_id),
            2 => optionalString(tool.turn_id),
            3 => optionalInteger(tool.turn_index),
            4 => optionalString(tool.started_at),
            5 => optionalString(tool.completed_at),
            6 => .{ .string = @tagName(tool.kind) },
            7 => optionalString(tool.tool_name),
            8 => optionalString(tool.namespace),
            9 => optionalJson(tool.arguments_json),
            10 => optionalString(tool.input_text),
            11 => optionalString(tool.output_text),
            12 => optionalString(tool.command_text),
            13 => optionalString(tool.cwd),
            14 => optionalInteger(tool.exit_code),
            15 => optionalInteger(tool.duration_ms),
            16 => .{ .string = @tagName(tool.lifecycle_status) },
            17 => optionalInteger(tool.declared_line),
            18 => optionalInteger(tool.finalized_line),
            19 => .{ .string = tool.path },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillSessionEdge(
    row: []execution.Value,
    fields: []const u16,
    edge: trace_core.SessionGraphEdge,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(edge.parent_session_id),
            1 => optionalString(edge.worker_session_id),
            2 => .{ .string = edge.parent_path },
            3 => optionalString(edge.worker_path),
            4 => optionalString(edge.call_id),
            5 => optionalString(edge.agent_nickname),
            6 => optionalString(edge.agent_role),
            7 => optionalString(edge.model),
            8 => optionalString(edge.reasoning_effort),
            9 => optionalString(edge.spawned_at),
            10 => optionalString(edge.worker_status),
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillTokenEvent(
    row: []execution.Value,
    fields: []const u16,
    session: trace_core.SessionRecord,
    occurrence: *const trace_core.TraceOccurrence,
    event: trace_core.TokenEventRecord,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(session.session_id),
            1 => .{ .integer = event.turn_index },
            2 => optionalString(occurrence.timestamp),
            3 => optionalInteger(event.input_tokens),
            4 => optionalInteger(event.cached_input_tokens),
            5 => optionalInteger(event.output_tokens),
            6 => optionalInteger(event.reasoning_output_tokens),
            7 => optionalInteger(event.total_tokens),
            8 => .{ .string = occurrence.sourceEventId() },
            9 => .{ .string = session.path },
            10 => optionalInteger(event.total_input_tokens),
            11 => optionalInteger(event.total_cached_input_tokens),
            12 => optionalInteger(event.total_output_tokens),
            13 => optionalInteger(event.total_reasoning_output_tokens),
            14 => optionalInteger(event.total_total_tokens),
            15 => optionalInteger(event.last_input_tokens),
            16 => optionalInteger(event.last_cached_input_tokens),
            17 => optionalInteger(event.last_output_tokens),
            18 => optionalInteger(event.last_reasoning_output_tokens),
            19 => optionalInteger(event.last_total_tokens),
            20 => .{ .boolean = event.has_total_usage },
            21 => .{ .boolean = event.has_last_usage },
            22 => .{ .string = tokenUsageState(event) },
            23 => try usizeInteger(occurrence.line_number),
            24 => try usizeInteger(event.occurrence_index),
            25 => optionalString(event.model),
            26 => optionalString(event.service_tier),
            27 => if (occurrence.timestamp) |timestamp|
                if (seq_time.parseIsoTimestampMillis(timestamp)) |millis|
                    .{ .integer = millis }
                else
                    .null
            else
                .null,
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn tokenUsageState(event: trace_core.TokenEventRecord) []const u8 {
    if (event.has_total_usage and event.has_last_usage) return "total-and-last";
    if (event.has_total_usage) return "total-only";
    if (event.has_last_usage) return "last-only";
    return "missing";
}

fn occurrenceAtLine(
    trace: *const trace_core.CanonicalSessionTrace,
    line_number: i64,
) ?*const trace_core.TraceOccurrence {
    const wanted = std.math.cast(usize, line_number) orelse return null;
    var low: usize = 0;
    var high = trace.occurrences.items.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const candidate = &trace.occurrences.items[middle];
        if (candidate.line_number < wanted) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low == trace.occurrences.items.len or
        trace.occurrences.items[low].line_number != wanted)
    {
        return null;
    }
    return &trace.occurrences.items[low];
}

fn optionalString(value: ?[]const u8) execution.Value {
    return if (value) |text| .{ .string = text } else .null;
}

fn optionalJson(value: ?[]const u8) execution.Value {
    return if (value) |json| .{ .json = json } else .null;
}

fn optionalInteger(value: ?i64) execution.Value {
    return if (value) |number| .{ .integer = number } else .null;
}

fn optionalBoolean(value: ?bool) execution.Value {
    return if (value) |flag| .{ .boolean = flag } else .null;
}

fn usizeInteger(value: usize) !execution.Value {
    return .{
        .integer = std.math.cast(i64, value) orelse
            return error.TraceIntegerOverflow,
    };
}

const session_observation_definition =
    \\{
    \\  "schema": "seq-observation-definition/v1",
    \\  "id": "example/sessions",
    \\  "requires": {
    \\    "abi": "seq-observation-abi/v1",
    \\    "operators": ["scan", "filter", "project"]
    \\  },
    \\  "parameters": {},
    \\  "selectors": ["path"],
    \\  "relations": [
    \\    {"name": "sessions", "fields": ["session_id", "path", "model",
    \\                                      "turn_count"]}
    \\  ],
    \\  "inputs": [],
    \\  "pipeline": [
    \\    {"op": "scan", "relation": "sessions", "as": "source"},
    \\    {"op": "filter", "input": "source", "as": "matched",
    \\     "where": [{"field": "model", "op": "exact", "value": "gpt-test"}]},
    \\    {"op": "project", "input": "matched", "as": "rows",
    \\     "fields": ["session_id", "turn_count"]}
    \\  ],
    \\  "projections": {
    \\    "rows": {"relation": "rows", "schema": "example-session-rows/v1",
    \\             "fields": ["session_id", "turn_count"], "renderers": ["json"]}
    \\  },
    \\  "bounds": {
    \\    "max_rows": 10,
    \\    "max_output_bytes": 4096,
    \\    "max_fold_states": 2
    \\  }
    \\}
;

const event_observation_definition =
    \\{
    \\  "schema": "seq-observation-definition/v1",
    \\  "id": "example/events",
    \\  "requires": {
    \\    "abi": "seq-observation-abi/v1",
    \\    "operators": ["scan", "filter", "project"]
    \\  },
    \\  "parameters": {},
    \\  "selectors": ["path"],
    \\  "relations": [{
    \\    "name": "source_events",
    \\    "fields": [
    \\      "source_event_id", "event_type", "role", "text", "raw_json",
    \\      "turn_index"
    \\    ]
    \\  }],
    \\  "inputs": [],
    \\  "pipeline": [
    \\    {"op": "scan", "relation": "source_events", "as": "source"},
    \\    {"op": "filter", "input": "source", "as": "matched",
    \\     "where": [{"field": "event_type", "op": "exact",
    \\                "value": "agent_message"}]},
    \\    {"op": "project", "input": "matched", "as": "rows",
    \\     "fields": ["source_event_id", "role", "text", "raw_json",
    \\                "turn_index"]}
    \\  ],
    \\  "projections": {
    \\    "rows": {"relation": "rows", "schema": "example-event-rows/v1",
    \\             "fields": ["source_event_id", "role", "text", "raw_json",
    \\                        "turn_index"], "renderers": ["json"]}
    \\  },
    \\  "bounds": {
    \\    "max_rows": 10,
    \\    "max_output_bytes": 4096,
    \\    "max_fold_states": 2
    \\  }
    \\}
;

const trace_rollout =
    "{\"timestamp\":\"2026-07-26T10:00:00Z\",\"type\":\"session_meta\"," ++
    "\"payload\":{\"id\":\"session-1\",\"model\":\"gpt-test\",\"cwd\":\"/repo\"}}\n" ++
    "{\"timestamp\":\"2026-07-26T10:00:01Z\",\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-1\"}}\n" ++
    "{\"timestamp\":\"2026-07-26T10:00:02Z\",\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"agent_message\",\"message\":\"observed\"}}\n" ++
    "{\"timestamp\":\"2026-07-26T10:00:03Z\",\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-1\"}}\n";

const TestProgram = struct {
    closure: definition_core.closure.Closure,
    definition_plan: definition.Plan,
    native_plan: plan.Plan,
    bindings: definition_core.parameters.Bindings,
    program: execution.Program,

    fn init(
        dir: *std.Io.Dir,
        path: []const u8,
        source: []const u8,
    ) !TestProgram {
        try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = source });
        var closure = try definition_core.closure.loadFromDir(
            std.testing.allocator,
            dir,
            path,
            .{},
        );
        errdefer closure.deinit(std.testing.allocator);
        var definition_plan = try definition.compile(
            std.testing.allocator,
            &closure,
            path,
        );
        errdefer definition_plan.deinit(std.testing.allocator);
        var native_plan = try plan.compile(std.testing.allocator, &definition_plan);
        errdefer native_plan.deinit(std.testing.allocator);
        var bindings = try definition_core.parameters.bind(
            std.testing.allocator,
            &definition_plan.parameter_declarations,
            &.{},
        );
        errdefer bindings.deinit(std.testing.allocator);
        return .{
            .closure = closure,
            .definition_plan = definition_plan,
            .native_plan = native_plan,
            .bindings = bindings,
            .program = try execution.compile(
                std.testing.allocator,
                &definition_plan,
                &native_plan,
                &bindings,
                "rows",
            ),
        };
    }

    fn deinit(self: *TestProgram) void {
        self.program.deinit(std.testing.allocator);
        self.bindings.deinit(std.testing.allocator);
        self.native_plan.deinit(std.testing.allocator);
        self.definition_plan.deinit(std.testing.allocator);
        self.closure.deinit(std.testing.allocator);
        self.* = undefined;
    }
};

fn expectSessionObservation(observation: *const Observation) !void {
    try std.testing.expectEqual(@as(usize, 4), observation.metrics.lines_seen);
    try std.testing.expectEqualStrings(
        "sha256:",
        observation.corpus_digest[0..7],
    );
    try std.testing.expectEqual(@as(usize, 1), observation.result.row_count);
    try std.testing.expectEqualStrings(
        "session-1",
        observation.result.rows().row(0)[0].string,
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        observation.result.rows().row(0)[1].integer,
    );
}

fn expectEventObservation(observation: *const Observation) !void {
    const row = observation.result.rows().row(0);
    try std.testing.expectEqual(@as(usize, 1), observation.result.row_count);
    try std.testing.expectEqualStrings("sha256:", row[0].string[0..7]);
    try std.testing.expectEqualStrings("assistant", row[1].string);
    try std.testing.expectEqualStrings("observed", row[2].string);
    try std.testing.expectEqualStrings(
        "{\"timestamp\":\"2026-07-26T10:00:02Z\",\"type\":\"event_msg\"," ++
            "\"payload\":{\"type\":\"agent_message\",\"message\":\"observed\"}}",
        row[3].json,
    );
    try std.testing.expectEqual(@as(i64, 1), row[4].integer);
}

test "trace adapter scans demanded session columns in one file pass" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "rollout.jsonl",
        .data = trace_rollout,
    });
    var session_program = try TestProgram.init(
        &tmp.dir,
        "observation.json",
        session_observation_definition,
    );
    defer session_program.deinit();

    const path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(path);
    var output: [2]execution.Value = undefined;
    var observation = try observeFile(
        std.testing.allocator,
        &session_program.program,
        path,
        .{ .ongoing_threshold_secs = 0 },
        &output,
    );
    defer observation.deinit(std.testing.allocator);
    try expectSessionObservation(&observation);

    var event_program = try TestProgram.init(
        &tmp.dir,
        "events.json",
        event_observation_definition,
    );
    defer event_program.deinit();

    var event_output: [5]execution.Value = undefined;
    var events = try observeFile(
        std.testing.allocator,
        &event_program.program,
        path,
        .{ .ongoing_threshold_secs = 0 },
        &event_output,
    );
    defer events.deinit(std.testing.allocator);
    try expectEventObservation(&events);
}

test "selector discovery replays the admitted prefix without a second read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "rollout.jsonl",
        .data = trace_rollout,
    });
    var event_program = try TestProgram.init(
        &tmp.dir,
        "events.json",
        event_observation_definition,
    );
    defer event_program.deinit();
    const path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(path);

    var selected = try parseFileSelected(
        std.testing.allocator,
        &event_program.program,
        path,
        .{},
        .{ .repo = "/repo" },
    );
    defer if (selected.parsed) |*parsed|
        parsed.deinit(std.testing.allocator);
    try std.testing.expect(selected.parsed != null);
    try std.testing.expectEqual(
        @as(usize, trace_rollout.len),
        selected.parsed.?.metrics.bytes_read,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        selected.discovery_bytes_read,
    );

    const rejected = try parseFileSelected(
        std.testing.allocator,
        &event_program.program,
        path,
        .{},
        .{ .repo = "/another-repo" },
    );
    try std.testing.expect(rejected.parsed == null);
    try std.testing.expectEqual(
        @as(usize, trace_rollout.len),
        rejected.discovery_bytes_read,
    );

    const excluded = try parseFileSelected(
        std.testing.allocator,
        &event_program.program,
        path,
        .{},
        .{ .exclude_session_id = "session-1" },
    );
    try std.testing.expect(excluded.parsed == null);
    try std.testing.expectEqual(
        @as(usize, trace_rollout.len),
        excluded.discovery_bytes_read,
    );
}

test "selector discovery reads a complete large session metadata record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(
        std.testing.allocator,
        "{\"timestamp\":\"2026-07-26T10:00:00Z\",\"type\":\"session_meta\"," ++
            "\"payload\":{\"id\":\"session-large\",\"model\":\"gpt-test\"," ++
            "\"cwd\":\"/repo\",\"padding\":\"",
    );
    try source.appendNTimes(std.testing.allocator, 'x', 17 * 1024);
    try source.appendSlice(
        std.testing.allocator,
        "\"}}\n" ++
            "{\"timestamp\":\"2026-07-26T10:00:01Z\",\"type\":\"event_msg\"," ++
            "\"payload\":{\"type\":\"agent_message\",\"message\":\"observed\"}}\n",
    );
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "rollout.jsonl",
        .data = source.items,
    });
    var event_program = try TestProgram.init(
        &tmp.dir,
        "events.json",
        event_observation_definition,
    );
    defer event_program.deinit();
    const path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(path);

    var selected = try parseFileSelected(
        std.testing.allocator,
        &event_program.program,
        path,
        .{},
        .{ .session_id = "session-large" },
    );
    defer if (selected.parsed) |*parsed|
        parsed.deinit(std.testing.allocator);
    try std.testing.expect(selected.parsed != null);
    try std.testing.expectEqual(source.items.len, selected.parsed.?.metrics.bytes_read);

    const rejected = try parseFileSelected(
        std.testing.allocator,
        &event_program.program,
        path,
        .{},
        .{ .session_id = "session-other" },
    );
    try std.testing.expect(rejected.parsed == null);
    try std.testing.expect(rejected.discovery_bytes_read > 16 * 1024);
}

test "trace adapter applies temporal selectors to physical event rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "rollout.jsonl",
        .data = trace_rollout,
    });
    var event_program = try TestProgram.init(
        &tmp.dir,
        "events.json",
        event_observation_definition,
    );
    defer event_program.deinit();
    const path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(path);
    var parsed = try parseFile(
        std.testing.allocator,
        &event_program.program,
        path,
        .{},
    );
    defer parsed.deinit(std.testing.allocator);
    var output: [5]execution.Value = undefined;
    var runner = try execution.Runner.initAlloc(
        std.testing.allocator,
        &event_program.program,
        &output,
    );
    defer runner.deinit();
    _ = try feedTraceSelected(
        &runner,
        &event_program.program,
        &parsed.trace,
        .{
            .since_ms = seq_time.parseIsoTimestampMillis(
                "2026-07-26T10:00:02Z",
            ),
            .until_ms = seq_time.parseIsoTimestampMillis(
                "2026-07-26T10:00:02Z",
            ),
        },
    );
    const result = try runner.finish();
    try std.testing.expectEqual(@as(usize, 1), result.row_count);
    try std.testing.expectEqualStrings(
        "observed",
        result.rows().row(0)[2].string,
    );
}
