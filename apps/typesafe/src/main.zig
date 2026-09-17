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
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len == 1 or std.mem.eql(u8, argv[1], "--help")) {
        try core_io.writeToStreamAllowBrokenPipe(std.Io.File.stdout(), usage);
        return;
    }
    if (std.mem.eql(u8, argv[1], "--version")) {
        try core_io.writeToStreamAllowBrokenPipe(std.Io.File.stdout(), app_meta.version);
        try core_io.writeToStreamAllowBrokenPipe(std.Io.File.stdout(), "\n");
        return;
    }
    const opts = parseArgs(argv) catch |err| return fail(err);
    const api_key = init.environ_map.get("TYPESAFE_API_KEY") orelse
        return fail(error.MissingApiKey);
    if (api_key.len == 0 or std.mem.indexOfAny(u8, api_key, "\r\n") != null)
        return fail(error.InvalidApiKey);
    const rubric = if (opts.rubric_path) |path| loadRubric(allocator, path) catch |err|
        return fail(err) else default_rubric;
    validateRubric(rubric) catch |err| return fail(err);

    var client = std.http.Client{ .allocator = allocator, .io = core_io.defaultIo() };
    defer client.deinit();
    try client.initDefaultProxies(allocator, init.environ_map);
    for (opts.documents) |path| {
        const document = readDocument(allocator, path) catch |err| return fail(err);
        const request_body = makeRequest(allocator, path, document, rubric) catch |err|
            return fail(err);
        const response_body = callTypeSafe(allocator, &client, api_key, request_body) catch |err|
            return fail(err);
        const report = parseResponse(allocator, path, rubric, response_body) catch |err|
            return fail(err);
        var out: std.Io.Writer.Allocating = .init(allocator);
        try std.json.Stringify.value(report, .{}, &out.writer);
        try out.writer.writeByte('\n');
        std.Io.File.stdout().writeStreamingAll(core_io.defaultIo(), out.written()) catch |err| {
            if (err == error.BrokenPipe) return;
            return err;
        };
    }
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

fn fail(err: anyerror) noreturn {
    var stderr_writer = std.Io.File.stderr().writer(core_io.defaultIo(), &.{});
    stderr_writer.interface.print("typesafe: {s}\n", .{@errorName(err)}) catch
        std.process.exit(1);
    std.process.exit(1);
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

fn loadRubric(allocator: std.mem.Allocator, path: []const u8) !Rubric {
    const bytes = try core_io.readFileAlloc(allocator, path, 64 * 1024);
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

fn readDocument(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = if (std.mem.eql(u8, path, "-"))
        try core_io.readStdinAlloc(allocator, max_document_bytes)
    else
        try core_io.readFileAlloc(allocator, path, max_document_bytes);
    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidDocumentText;
    return bytes;
}

fn makeRequest(
    allocator: std.mem.Allocator,
    path: []const u8,
    document: []const u8,
    rubric: Rubric,
) ![]u8 {
    var questions: std.json.ObjectMap = .empty;
    for (rubric.dimensions) |dimension| {
        const question = .{
            .type = "score",
            .instructions = dimension.instructions,
            .criteria = dimension.levels,
        };
        var value_writer: std.Io.Writer.Allocating = .init(allocator);
        try std.json.Stringify.value(question, .{}, &value_writer.writer);
        const raw_question = value_writer.written();
        const value = try std.json.parseFromSlice(std.json.Value, allocator, raw_question, .{});
        try questions.put(allocator, dimension.id, value.value);
    }
    const payload = .{
        .state = .{ .document = .{ .name = path, .text = document } },
        .model = "jev-latest",
        .questions = std.json.Value{ .object = questions },
    };
    var writer: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(payload, .{}, &writer.writer);
    if (writer.written().len > 1024 * 1024) return error.RequestTooLarge;
    return writer.written();
}

fn callTypeSafe(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    api_key: []const u8,
    request_body: []const u8,
) ![]u8 {
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    const buffer = try allocator.alloc(u8, max_response_bytes);
    for (0..3) |attempt| {
        var writer: std.Io.Writer = .fixed(buffer);
        const result = client.fetch(.{
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
        const code = @intFromEnum(result.status);
        if ((result.status == .too_many_requests or code == 529) and attempt < 2) {
            const delay_ms: i64 = if (attempt == 0) 250 else 500;
            try std.Io.sleep(client.io, .fromMilliseconds(delay_ms), .awake);
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
            const key = try std.fmt.allocPrint(allocator, "{d}", .{level});
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
