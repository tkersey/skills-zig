const std = @import("std");
const core_io = @import("core_io");
const app_meta = @import("app_meta");

const max_document_bytes = 512 * 1024;
const max_response_bytes = 1024 * 1024;
const max_documents = 32;
const max_dimensions = 8;
const endpoint = "https://api.typesafe.ai/v1/systemone";

const Dimension = struct {
    id: []const u8,
    instructions: []const u8,
    levels: []const []const u8,
    review_below: f64,
};

const Rubric = struct { dimensions: []const Dimension };

const default_dimensions = [_]Dimension{.{
    .id = "technical_accuracy",
    .instructions = "Based only on `document.text`, how technically sound are its claims? " ++
        "Judge apparent errors, contradictions, and misuse of technical terms. " ++
        "Do not assume unstated external evidence or treat this as fact verification.",
    .levels = &.{
        "Clear technical errors or contradictions undermine the document.",
        "Several claims appear technically questionable or inconsistent.",
        "Mostly coherent, with a specific technical uncertainty worth reviewing.",
        "Technically coherent with no apparent error in the supplied text.",
    },
    .review_below = 2.0,
}};
const default_rubric = Rubric{ .dimensions = &default_dimensions };

const Options = struct {
    rubric_path: ?[]const u8 = null,
    documents: []const []const u8,
};

const DimensionResult = struct {
    id: []const u8,
    score: f64,
    max_score: usize,
    levels: []const []const u8,
    review_below: f64,
    confidence: f64,
    review: bool,
    probabilities: std.json.Value,
};

const Report = struct {
    document: []const u8,
    model: []const u8,
    needs_review: bool,
    dimensions: []const DimensionResult,
    usage: std.json.Value,
};

pub fn main(init: std.process.Init) !void {
    const code = try run(init);
    if (code != 0) std.process.exit(code);
}

fn run(init: std.process.Init) !u8 {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len == 1 or std.mem.eql(u8, argv[1], "--help")) {
        std.Io.File.stdout().writeStreamingAll(init.io, usage) catch |err| {
            if (err != error.BrokenPipe) return err;
        };
        return 0;
    }
    if (std.mem.eql(u8, argv[1], "--version")) {
        std.Io.File.stdout().writeStreamingAll(init.io, app_meta.version ++ "\n") catch |err| {
            if (err != error.BrokenPipe) return err;
        };
        return 0;
    }
    const opts = parseArgs(argv) catch |err| return fail(init.io, err);
    const api_key = init.environ_map.get("TYPESAFE_API_KEY") orelse
        return fail(init.io, error.MissingApiKey);
    if (api_key.len == 0 or std.mem.indexOfAny(u8, api_key, "\r\n") != null)
        return fail(init.io, error.InvalidApiKey);
    const directory = std.Io.Dir.cwd();
    const rubric = if (opts.rubric_path) |path| loadRubric(
        allocator,
        init.io,
        directory,
        path,
    ) catch |err|
        return fail(init.io, err) else default_rubric;
    validateRubric(rubric) catch |err| return fail(init.io, err);

    var client = std.http.Client{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    try client.initDefaultProxies(allocator, init.environ_map);
    var transport = HttpTransport{ .client = &client };
    var output = std.Io.File.stdout().writerStreaming(init.io, &.{});
    const result = runDocuments(
        init.gpa,
        init.io,
        directory,
        opts.documents,
        rubric,
        api_key,
        &transport,
        &output.interface,
    ) catch |err| {
        if (output.err) |write_error| {
            if (core_io.isClosedPipeError(write_error)) return 0;
            return write_error;
        }
        return err;
    };
    return switch (result) {
        .complete => 0,
        .command_error => |err| fail(init.io, err),
    };
}

const BatchResult = union(enum) { complete, command_error: anyerror };

// Transport/client state and the rubric outlive this operation. Only the
// document arena is passed to request/response/report construction.
fn runDocuments(
    backing: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    paths: []const []const u8,
    rubric: Rubric,
    api_key: []const u8,
    transport: anytype,
    output: *std.Io.Writer,
) !BatchResult {
    for (paths) |path| {
        var document_arena = std.heap.ArenaAllocator.init(backing);
        defer document_arena.deinit();
        const allocator = document_arena.allocator();
        const document = readDocument(allocator, io, directory, path) catch |err|
            return .{ .command_error = err };
        const request_body = makeRequest(allocator, path, document, rubric) catch |err|
            return .{ .command_error = err };
        const response_body = callTypeSafe(allocator, transport, api_key, request_body) catch |err|
            return .{ .command_error = err };
        const report = parseResponse(allocator, path, rubric, response_body) catch |err|
            return .{ .command_error = err };
        var out: std.Io.Writer.Allocating = .init(allocator);
        try std.json.Stringify.value(report, .{}, &out.writer);
        try out.writer.writeByte('\n');
        try output.writeAll(out.written());
        try output.flush();
    }
    return .complete;
}

const usage =
    \\typesafe [--rubric FILE] DOCUMENT [DOCUMENT ...]
    \\
    \\Evaluate UTF-8 text or Markdown documents with TypeSafe.
    \\Use - for stdin. Set TYPESAFE_API_KEY in the environment.
    \\Writes one JSON result per document; review flags are triage signals,
    \\not verified findings. Maximum: 32 documents, 512 KiB each.
    \\Options: --rubric FILE, --help, --version
    \\
;

fn fail(io: std.Io, err: anyerror) u8 {
    var stderr_writer = std.Io.File.stderr().writer(io, &.{});
    stderr_writer.interface.print("typesafe: {s}\n", .{@errorName(err)}) catch
        return 1;
    return 1;
}

fn parseArgs(argv: []const []const u8) !Options {
    var rubric_path: ?[]const u8 = null;
    var first_document: ?usize = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--rubric")) {
            if (rubric_path != null or first_document != null) return error.InvalidArguments;
            i += 1;
            if (i >= argv.len) return error.MissingRubricPath;
            rubric_path = argv[i];
        } else {
            first_document = i;
            break;
        }
    }
    const first = first_document orelse return error.MissingDocument;
    const documents = argv[first..];
    if (documents.len > max_documents) return error.TooManyDocuments;
    for (documents) |path| {
        if (path.len == 0 or (path[0] == '-' and !std.mem.eql(u8, path, "-")))
            return error.InvalidDocumentPath;
    }
    return .{ .rubric_path = rubric_path, .documents = documents };
}

fn loadRubric(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
) !Rubric {
    const bytes = try directory.readFileAlloc(io, path, allocator, .limited(64 * 1024));
    const parsed = try std.json.parseFromSlice(Rubric, allocator, bytes, .{});
    return parsed.value;
}

fn validateRubric(rubric: Rubric) !void {
    if (rubric.dimensions.len == 0 or rubric.dimensions.len > max_dimensions)
        return error.InvalidDimensionCount;
    for (rubric.dimensions, 0..) |dimension, i| {
        if (dimension.id.len == 0 or dimension.instructions.len == 0 or
            dimension.levels.len < 2 or dimension.levels.len > 6 or
            !std.math.isFinite(dimension.review_below) or
            dimension.review_below < 0 or
            dimension.review_below > @as(f64, @floatFromInt(dimension.levels.len - 1)))
            return error.InvalidDimension;
        for (dimension.id) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidDimensionId;
        }
        for (dimension.levels) |level| if (level.len == 0) return error.EmptyLevel;
        for (rubric.dimensions[0..i]) |previous| {
            if (std.mem.eql(u8, previous.id, dimension.id)) return error.DuplicateDimensionId;
        }
    }
}

fn readDocument(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
) ![]u8 {
    const bytes = if (std.mem.eql(u8, path, "-")) stdin: {
        var reader = std.Io.File.stdin().reader(io, &.{});
        break :stdin try reader.interface.allocRemaining(allocator, .limited(max_document_bytes));
    } else try directory.readFileAlloc(io, path, allocator, .limited(max_document_bytes));
    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidDocumentText;
    return bytes;
}

fn makeRequest(
    allocator: std.mem.Allocator,
    path: []const u8,
    document: []const u8,
    rubric: Rubric,
) ![]u8 {
    const payload = .{
        .state = .{ .document = .{ .name = path, .text = document } },
        .model = "jev-latest",
        .questions = Questions{ .rubric = rubric },
    };
    var writer: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(payload, .{}, &writer.writer);
    if (writer.written().len > 1024 * 1024) return error.RequestTooLarge;
    return writer.written();
}

const Questions = struct {
    rubric: Rubric,

    pub fn jsonStringify(self: Questions, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        for (self.rubric.dimensions) |dimension| {
            try writer.objectField(dimension.id);
            try writer.write(.{
                .type = "score",
                .instructions = dimension.instructions,
                .criteria = dimension.levels,
            });
        }
        try writer.endObject();
    }
};

const HttpTransport = struct {
    client: *std.http.Client,

    fn fetch(
        self: *HttpTransport,
        options: std.http.Client.FetchOptions,
    ) !std.http.Client.FetchResult {
        return self.client.fetch(options);
    }

    fn sleep(self: *HttpTransport, milliseconds: i64) !void {
        try std.Io.sleep(self.client.io, .fromMilliseconds(milliseconds), .awake);
    }
};

fn callTypeSafe(
    allocator: std.mem.Allocator,
    transport: anytype,
    api_key: []const u8,
    request_body: []const u8,
) ![]u8 {
    const auth = try allocator.print("Bearer {s}", .{api_key});
    const buffer = try allocator.alloc(u8, max_response_bytes);
    for (0..3) |attempt| {
        var writer: std.Io.Writer = .fixed(buffer);
        const result = transport.fetch(.{
            .location = .{ .url = endpoint },
            .method = .POST,
            .payload = request_body,
            .redirect_behavior = .not_allowed,
            .headers = .{
                .authorization = .{ .override = auth },
                .content_type = .{ .override = "application/json" },
            },
            .response_writer = &writer,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.ResponseTooLarge,
            else => return err,
        };
        if (result.status == .ok) return writer.buffered();
        const code = @backingInt(result.status);
        if ((result.status == .too_many_requests or code == 529) and attempt < 2) {
            const delay_ms: i64 = if (attempt == 0) 250 else 500;
            try transport.sleep(delay_ms);
            continue;
        }
        return switch (result.status) {
            .unauthorized => error.TypeSafeUnauthorized,
            .unprocessable_entity => error.TypeSafeInvalidRequest,
            .too_many_requests => error.TypeSafeRateLimited,
            else => if (code == 529) error.TypeSafeOverloaded else error.TypeSafeApiFailure,
        };
    }
    unreachable;
}

fn parseResponse(
    allocator: std.mem.Allocator,
    path: []const u8,
    rubric: Rubric,
    body: []const u8,
) !Report {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    const root = object(parsed.value) orelse return error.InvalidApiResponse;
    const model = string(root.get("model") orelse return error.InvalidApiResponse) orelse
        return error.InvalidApiResponse;
    const answers = object(root.get("answers") orelse return error.InvalidApiResponse) orelse
        return error.InvalidApiResponse;
    if (answers.count() != rubric.dimensions.len) return error.InvalidApiResponse;
    const token_usage = root.get("usage") orelse return error.InvalidApiResponse;
    if (object(token_usage) == null) return error.InvalidApiResponse;
    const results = try allocator.alloc(DimensionResult, rubric.dimensions.len);
    var needs_review = false;
    for (rubric.dimensions, 0..) |dimension, i| {
        const answer_value = answers.get(dimension.id) orelse return error.InvalidApiResponse;
        const answer = object(answer_value) orelse
            return error.InvalidApiResponse;
        const answer_type = string(answer.get("type") orelse return error.InvalidApiResponse) orelse
            return error.InvalidApiResponse;
        if (!std.mem.eql(u8, answer_type, "score")) return error.InvalidApiResponse;
        const score = number(answer.get("score") orelse return error.InvalidApiResponse) orelse
            return error.InvalidApiResponse;
        const confidence_value = answer.get("confidence") orelse return error.InvalidApiResponse;
        const confidence = number(confidence_value) orelse
            return error.InvalidApiResponse;
        const probabilities = answer.get("probabilities") orelse return error.InvalidApiResponse;
        const probability_map = object(probabilities) orelse return error.InvalidApiResponse;
        if (!std.math.isFinite(score) or score < 0 or
            score > @as(f64, @floatFromInt(dimension.levels.len - 1)) or
            !std.math.isFinite(confidence) or confidence < 0 or confidence > 1 or
            probability_map.count() != dimension.levels.len)
            return error.InvalidApiResponse;
        var probability_sum: f64 = 0;
        for (dimension.levels, 0..) |_, level| {
            const key = try allocator.print("{d}", .{level});
            const probability = number(probability_map.get(key) orelse
                return error.InvalidApiResponse) orelse return error.InvalidApiResponse;
            if (!std.math.isFinite(probability) or probability < 0 or probability > 1)
                return error.InvalidApiResponse;
            probability_sum += probability;
        }
        if (@abs(probability_sum - 1) > 0.02) return error.InvalidApiResponse;
        const review = score < dimension.review_below;
        needs_review = needs_review or review;
        results[i] = .{
            .id = dimension.id,
            .score = score,
            .max_score = dimension.levels.len - 1,
            .levels = dimension.levels,
            .review_below = dimension.review_below,
            .confidence = confidence,
            .review = review,
            .probabilities = probabilities,
        };
    }
    return .{
        .document = path,
        .model = model,
        .needs_review = needs_review,
        .dimensions = results,
        .usage = token_usage,
    };
}

fn object(value: std.json.Value) ?std.json.ObjectMap {
    return if (value == .object) value.object else null;
}

fn string(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

fn number(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |n| n,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

test "rubric rejects duplicate dimensions" {
    const dimensions = [_]Dimension{ default_dimensions[0], default_dimensions[0] };
    try std.testing.expectError(error.DuplicateDimensionId, validateRubric(.{
        .dimensions = &dimensions,
    }));
}

test "request batches independent dimensions over one document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const dimensions = [_]Dimension{
        default_dimensions[0],
        .{
            .id = "clarity",
            .instructions = "How clear is `document.text`?",
            .levels = &.{ "Unclear", "Clear" },
            .review_below = 0.5,
        },
    };
    const request = try makeRequest(allocator, "example.md", "hello", .{
        .dimensions = &dimensions,
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
    const root = object(parsed.value).?;
    const questions = object(root.get("questions").?).?;
    try std.testing.expectEqual(@as(usize, 2), questions.count());
    try std.testing.expect(questions.get("technical_accuracy") != null);
    try std.testing.expect(questions.get("clarity") != null);
}

test "low score flags review and missing answer fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body =
        \\{"model":"jev-latest","answers":{"technical_accuracy":{"type":"score",
        \\"score":1.5,"confidence":0.8,"probabilities":{"0":0.1,"1":0.4,
        \\"2":0.4,"3":0.1}}},"usage":{"input_tokens":10,"output_tokens":5}}
    ;
    const report = try parseResponse(allocator, "example.md", default_rubric, body);
    try std.testing.expect(report.needs_review);
    try std.testing.expectEqual(@as(f64, 1.5), report.dimensions[0].score);
    try std.testing.expectError(error.InvalidApiResponse, parseResponse(
        allocator,
        "example.md",
        default_rubric,
        "{\"model\":\"jev-latest\",\"answers\":{},\"usage\":{}}",
    ));
}

const test_response =
    \\{"model":"jev-latest","answers":{"technical_accuracy":{"type":"score",
    \\"score":1.5,"confidence":0.8,"probabilities":{"0":0.1,"1":0.4,
    \\"2":0.4,"3":0.1}}},"usage":{"input_tokens":10,"output_tokens":5}}
;

const FakeTransport = struct {
    body: []const u8 = test_response,
    statuses: []const std.http.Status = &.{.ok},
    calls: usize = 0,
    delays: [2]i64 = undefined,
    delay_count: usize = 0,
    oversized: bool = false,
    fail_at: ?usize = null,
    fail_sleep: bool = false,
    document_allocations: ?*std.testing.FailingAllocator = null,
    live_at_fetch: ?usize = null,

    fn fetch(
        self: *FakeTransport,
        options: std.http.Client.FetchOptions,
    ) !std.http.Client.FetchResult {
        try std.testing.expectEqualStrings(endpoint, options.location.url);
        try std.testing.expectEqual(std.http.Method.POST, options.method.?);
        try std.testing.expectEqualStrings(
            "Bearer test-key",
            options.headers.authorization.override,
        );
        try std.testing.expectEqualStrings(
            "application/json",
            options.headers.content_type.override,
        );
        try std.testing.expect(options.redirect_behavior.? == .not_allowed);
        try std.testing.expect(options.payload != null);
        if (self.document_allocations) |allocations| {
            const live = allocations.allocated_bytes - allocations.freed_bytes;
            // Includes arena backing storage, measured below the arena.
            try std.testing.expect(live >= max_response_bytes);
            if (self.live_at_fetch) |previous| try std.testing.expectEqual(previous, live);
            self.live_at_fetch = live;
        }
        const call = self.calls;
        self.calls += 1;
        if (self.fail_at == call) return error.ConnectionResetByPeer;
        if (self.oversized) {
            try options.response_writer.?.splatByteAll('x', max_response_bytes + 1);
        } else {
            try options.response_writer.?.writeAll(self.body);
        }
        return .{ .status = self.statuses[@min(call, self.statuses.len - 1)] };
    }

    fn sleep(self: *FakeTransport, milliseconds: i64) !void {
        if (self.fail_sleep) return error.Canceled;
        try std.testing.expect(self.delay_count < self.delays.len);
        self.delays[self.delay_count] = milliseconds;
        self.delay_count += 1;
    }
};

const CheckingOutput = struct {
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
    bytes: std.ArrayList(u8) = .empty,
    writes: usize = 0,
    fail_at: ?usize = null,
    document_allocations: ?*std.testing.FailingAllocator = null,

    fn deinit(self: *CheckingOutput) void {
        self.bytes.deinit(std.testing.allocator);
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *CheckingOutput = @alignCast(@fieldParentPtr("writer", writer));
        if (self.document_allocations) |allocations| {
            std.debug.assert(allocations.allocated_bytes > allocations.freed_bytes);
        }
        if (self.fail_at == self.writes) return error.WriteFailed;
        self.writes += 1;
        for (data[0 .. data.len - 1]) |bytes| {
            self.bytes.appendSlice(std.testing.allocator, bytes) catch return error.WriteFailed;
        }
        for (0..splat) |_| {
            self.bytes.appendSlice(
                std.testing.allocator,
                data[data.len - 1],
            ) catch return error.WriteFailed;
        }
        return std.Io.Writer.countSplat(data, splat);
    }
};

test "request writes dynamic questions directly with exact escaping and field order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dimensions = [_]Dimension{.{
        .id = "a",
        .instructions = "quote\"\n",
        .levels = &.{ "low", "high" },
        .review_below = 0.5,
    }};
    const request = try makeRequest(
        arena.allocator(),
        "a\".md",
        "text\n\\é",
        .{ .dimensions = &dimensions },
    );
    try std.testing.expectEqualStrings(
        "{\"state\":{\"document\":{\"name\":\"a\\\".md\",\"text\":\"text\\n\\\\é\"}}," ++
            "\"model\":\"jev-latest\",\"questions\":{\"a\":{\"t" ++
            "ype\":\"score\",\"instructions\":\"quote\\\"\\n\"," ++
            "\"criteria\":[\"low\",\"high\"]}}}",
        request,
    );
}

test "one and 32 documents release each arena after writing its report" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.md", .data = "text\n\"quoted\"" });
    for ([_]usize{ 1, 32 }) |count| {
        // Force relocation so backing-memory size is independent of whether
        // the test allocator happens to grow its last bucket in place.
        var tracking = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .resize_fail_index = 0 },
        );
        var transport = FakeTransport{ .document_allocations = &tracking };
        var output = CheckingOutput{ .document_allocations = &tracking };
        defer output.deinit();
        const paths: [32][]const u8 = @splat("a.md");
        try std.testing.expect(
            try runDocuments(
                tracking.allocator(),
                std.testing.io,
                tmp.dir,
                paths[0..count],
                default_rubric,
                "test-key",
                &transport,
                &output.writer,
            ) == .complete,
        );
        try std.testing.expectEqual(count, transport.calls);
        try std.testing.expectEqual(count, output.writes);
        try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
        // Only the output's independent copy survives document reclamation.
        var lines = std.mem.tokenizeScalar(u8, output.bytes.items, '\n');
        var line_count: usize = 0;
        while (lines.next()) |line| {
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                std.testing.allocator,
                line,
                .{},
            );
            defer parsed.deinit();
            try std.testing.expectEqualStrings(
                "a.md",
                parsed.value.object.get("document").?.string,
            );
            try std.testing.expect(parsed.value.object.get("needs_review").?.bool);
            try std.testing.expectEqual(
                @as(f64, 1.5),
                parsed.value.object.get("dimensions").?.array.items[0].object.get("score").?.float,
            );
            line_count += 1;
        }
        try std.testing.expectEqual(count, line_count);
    }
}

test "HTTP retries retain request policy and bounded response handling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var transport = FakeTransport{ .statuses = &.{
        .too_many_requests,
        @fromBackingInt(@intCast(529)),
        .ok,
    } };
    const response = try callTypeSafe(allocator, &transport, "test-key", "{}");
    try std.testing.expectEqualStrings(test_response, response);
    try std.testing.expectEqual(@as(usize, 3), transport.calls);
    try std.testing.expectEqualSlices(i64, &.{ 250, 500 }, &transport.delays);
    var oversized = FakeTransport{ .oversized = true };
    try std.testing.expectError(
        error.ResponseTooLarge,
        callTypeSafe(allocator, &oversized, "test-key", "{}"),
    );
    try std.testing.expectEqual(@as(usize, 1), oversized.calls);
    var canceled = FakeTransport{ .statuses = &.{.too_many_requests}, .fail_sleep = true };
    try std.testing.expectError(
        error.Canceled,
        callTypeSafe(allocator, &canceled, "test-key", "{}"),
    );
    for ([_]struct { status: std.http.Status, err: anyerror, calls: usize }{
        .{ .status = .unauthorized, .err = error.TypeSafeUnauthorized, .calls = 1 },
        .{ .status = .unprocessable_entity, .err = error.TypeSafeInvalidRequest, .calls = 1 },
        .{ .status = .too_many_requests, .err = error.TypeSafeRateLimited, .calls = 3 },
        .{ .status = @fromBackingInt(@intCast(529)), .err = error.TypeSafeOverloaded, .calls = 3 },
        .{ .status = .internal_server_error, .err = error.TypeSafeApiFailure, .calls = 1 },
    }) |case| {
        var failed = FakeTransport{ .statuses = &.{case.status} };
        try std.testing.expectError(case.err, callTypeSafe(allocator, &failed, "test-key", "{}"));
        try std.testing.expectEqual(case.calls, failed.calls);
    }
}

test "batch failure reclaims document state and stops later requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.md", .data = "text" });
    for (0..4) |case| {
        var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var transport = FakeTransport{
            .body = if (case == 0) "{}" else test_response,
            .fail_at = if (case == 1) 1 else null,
            .oversized = case == 2,
        };
        var output = CheckingOutput{ .fail_at = if (case == 3) 0 else null };
        defer output.deinit();
        const result = runDocuments(
            tracking.allocator(),
            std.testing.io,
            tmp.dir,
            &.{ "a.md", "a.md", "a.md" },
            default_rubric,
            "test-key",
            &transport,
            &output.writer,
        );
        if (case == 3) {
            try std.testing.expectError(error.WriteFailed, result);
        } else {
            const expected: anyerror = switch (case) {
                0 => error.InvalidApiResponse,
                1 => error.ConnectionResetByPeer,
                else => error.ResponseTooLarge,
            };
            try std.testing.expectEqual(expected, (try result).command_error);
        }
        try std.testing.expectEqual(@as(usize, if (case == 1) 2 else 1), transport.calls);
        try std.testing.expectEqual(@as(usize, if (case == 1) 1 else 0), output.writes);
        try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    }
}

test "CLI parser preserves option-looking values and product aliases" {
    const opts = try parseArgs(&.{ "typesafe", "--rubric", "--help", "a.md" });
    try std.testing.expectEqualStrings("--help", opts.rubric_path.?);
    try std.testing.expectError(error.MissingRubricPath, parseArgs(&.{ "typesafe", "--rubric" }));
    try std.testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "typesafe", "--rubric", "x", "--rubric", "y", "a" }),
    );
    for ([_][]const u8{ "-h", "-V", "--unknown", "--" }) |arg| {
        try std.testing.expectError(error.InvalidDocumentPath, parseArgs(&.{ "typesafe", arg }));
    }
}

test "proven broken pipe stops the batch after its first request" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.md", .data = "text" });
    var transport = FakeTransport{};
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    // The failing I/O implementation reports BrokenPipe for positional writes;
    // document reads still use the independent supplied testing I/O capability.
    var output = std.Io.File.stdout().writer(.failing, &.{});
    try std.testing.expectError(error.WriteFailed, runDocuments(
        tracking.allocator(),
        std.testing.io,
        tmp.dir,
        &.{ "a.md", "a.md" },
        default_rubric,
        "test-key",
        &transport,
        &output.interface,
    ));
    try std.testing.expect(core_io.isClosedPipeError(output.err.?));
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
    try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
}

fn batchAllocationProbe(allocator: std.mem.Allocator, directory: std.Io.Dir) !void {
    var transport = FakeTransport{};
    var output = CheckingOutput{};
    defer output.deinit();
    const result = runDocuments(
        allocator,
        std.testing.io,
        directory,
        &.{ "a.md", "a.md" },
        default_rubric,
        "test-key",
        &transport,
        &output.writer,
    ) catch |err| {
        // This stage's allocating JSON writer can only fail from OOM.
        if (err == error.WriteFailed) return error.OutOfMemory;
        return err;
    };
    switch (result) {
        .complete => {},
        .command_error => |err| return if (err == error.WriteFailed) error.OutOfMemory else err,
    }
}

test "document arenas release partial state at every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.md", .data = "text" });
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        batchAllocationProbe,
        .{tmp.dir},
    );
}
