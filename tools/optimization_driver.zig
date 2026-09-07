const std = @import("std");
const builtin = @import("builtin");
const core_perf = @import("core_perf");
const definition_core = @import("definition_core");
const ledger = @import("ledger_v1_core");
const trace = @import("trace_core");

const warmup_count = 3;
const sample_count = 30;
const fixture_limit = 32 * 1024 * 1024;
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Case = struct {
    id: []const u8,
    binary: []const u8,
    rows: usize = 0,
    limit: usize = 0,
    turns: usize = 0,
    summary: bool = false,
};

const cases = [_]Case{
    .{ .id = "ledger-topk-16384-k100", .binary = "ledger", .rows = 16384, .limit = 100 },
    .{ .id = "ledger-topk-16384-k1", .binary = "ledger", .rows = 16384, .limit = 1 },
    .{ .id = "ledger-topk-16384-k10", .binary = "ledger", .rows = 16384, .limit = 10 },
    .{ .id = "ledger-topk-16384-k1000", .binary = "ledger", .rows = 16384, .limit = 1000 },
    .{ .id = "ledger-topk-32-k10", .binary = "ledger", .rows = 32, .limit = 10 },
    .{ .id = "trace-full-1024", .binary = "seq", .turns = 1024 },
    .{ .id = "trace-full-8", .binary = "seq", .turns = 8 },
    .{ .id = "trace-summary-1024", .binary = "seq", .turns = 1024, .summary = true },
    .{ .id = "trace-summary-8", .binary = "seq", .turns = 8, .summary = true },
};

const Metrics = struct {
    samples_ns: [sample_count]u64,
    p50_ns: u64,
    p95_ns: u64,
    p50_alloc_calls: u64,
};

const Fixture = struct {
    bytes: []u8,
    definition: []u8,
    expected: []u8,
    root: []u8,
    plans: ?ledger.compiled_plan.PlanSet = null,
    parameters: ?definition_core.parameters.Bindings = null,

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        if (self.parameters) |*value| value.deinit(allocator);
        if (self.plans) |*value| value.deinit(allocator);
        std.Io.Dir.cwd().deleteTree(io(), self.root) catch |err| {
            std.debug.print("optimization fixture cleanup: {s}\n", .{@errorName(err)});
        };
        allocator.free(self.bytes);
        allocator.free(self.definition);
        allocator.free(self.expected);
        allocator.free(self.root);
    }
};

const Output = union(enum) {
    ledger: ledger.projection.Result,
    trace: trace.CanonicalSessionTrace,

    fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*value| value.deinit(allocator),
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 4 or !std.mem.eql(u8, argv[2], "--target")) {
        return error.InvalidCommand;
    }
    const capture = std.mem.eql(u8, argv[1], "capture");
    if (!capture and !std.mem.eql(u8, argv[1], "oracle")) return error.InvalidCommand;
    const case = try findCase(argv[3]);
    var fixture = try prepareFixture(allocator, case);
    defer fixture.deinit(allocator);
    const expected_digest = digest_block: {
        var output = try execute(allocator, case, &fixture);
        defer output.deinit(allocator);
        break :digest_block try outputDigest(allocator, case, &fixture, output);
    };
    if (!capture) return writeOracle(case, fixture, expected_digest);
    const metrics = try measure(allocator, case, &fixture, expected_digest);
    try writeArtifact(allocator, case, fixture, metrics, expected_digest);
    var stdout = std.Io.File.stdout().writer(io(), &.{});
    try stdout.interface.print("PASS\t{s}\tcaptured\n", .{case.id});
}

fn findCase(id: []const u8) !Case {
    for (cases) |case| if (std.mem.eql(u8, case.id, id)) return case;
    return error.UnknownCase;
}

fn prepareFixture(allocator: std.mem.Allocator, case: Case) !Fixture {
    var fixture = try allocateFixture(allocator, case);
    errdefer fixture.deinit(allocator);
    if (case.rows > 0) try prepareLedger(allocator, &fixture);
    return fixture;
}

fn allocateFixture(allocator: std.mem.Allocator, case: Case) !Fixture {
    const root = try std.fmt.allocPrint(
        allocator,
        "{s}/skills-zig-optimization-{d}",
        .{
            if (builtin.os.tag == .macos) "/private/tmp" else "/tmp",
            std.Io.Clock.awake.now(io()).nanoseconds,
        },
    );
    errdefer allocator.free(root);
    const bytes = if (case.rows > 0)
        try ledgerBytes(allocator, case.rows)
    else
        try traceBytes(allocator, case.turns);
    errdefer allocator.free(bytes);
    if (bytes.len > fixture_limit) return error.FixtureTooLarge;
    const definition = try definitionBytes(allocator, case.limit);
    errdefer allocator.free(definition);
    const expected = try expectedLedger(allocator, case);
    errdefer allocator.free(expected);
    try std.Io.Dir.createDirAbsolute(io(), root, .fromMode(0o700));
    return Fixture{
        .root = root,
        .bytes = bytes,
        .definition = definition,
        .expected = expected,
    };
}

fn prepareLedger(allocator: std.mem.Allocator, fixture: *Fixture) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io(), fixture.root, .{});
    defer dir.close(io());
    try dir.writeFile(io(), .{ .sub_path = "definition.json", .data = fixture.definition });
    try dir.createDirPath(io(), ".ledger/optimization");
    try dir.writeFile(io(), .{
        .sub_path = ".ledger/optimization/events.jsonl",
        .data = fixture.bytes,
    });
    var bind_plans = try ledger.compiled_plan.load(
        allocator,
        fixture.root,
        "definition.json",
        .{ .kind = .transact, .name = "bind-existing" },
        "1.0.0",
        .{},
    );
    defer bind_plans.deinit(allocator);
    fixture.parameters = try definition_core.parameters.bind(
        allocator,
        &bind_plans.definition_plan.parameter_declarations,
        &.{},
    );
    var binding = try ledger.transaction.transact(
        allocator,
        &bind_plans.definition_plan,
        &bind_plans.closure,
        "definition.json",
        &bind_plans.validation_plan.?,
        &bind_plans.storage_plan.?,
        if (bind_plans.protocol_plan) |*value| value else null,
        "bind-existing",
        fixture.root,
        &.{},
        &fixture.parameters.?,
    );
    defer binding.deinit(allocator);
    if (!binding.storage_mutated) return error.FixtureBindingFailed;
    fixture.plans = try ledger.compiled_plan.load(
        allocator,
        fixture.root,
        "definition.json",
        .{ .kind = .project, .name = "rows" },
        "1.0.0",
        .{},
    );
}

fn definitionBytes(allocator: std.mem.Allocator, limit: usize) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"ledger-artifact-definition/v1\",\"id\":\"optimization/topk\"," ++
            "\"owner\":\"optimization\",\"requires\":{{\"abi\":\"ledger-artifact-abi/v1\"," ++
            "\"operators\":[\"atomic-transaction\",\"bind-existing\",\"limit\"," ++
            "\"select\",\"sort\"]}},\"parameters\":{{}}," ++
            "\"inputs\":{{\"event\":{{\"codec\":\"json\",\"max_bytes\":4096}}}}," ++
            "\"canonicalization\":{{}},\"shape\":{{}},\"constraints\":{{\"laws\":[]}}," ++
            "\"identity\":{{}},\"storage\":{{\"kind\":\"event-log\",\"slots\":{{\"events\":{{" ++
            "\"path\":\"optimization/events.jsonl\",\"kind\":\"event-log\",\"codec\":\"jsonl\"," ++
            "\"max_bytes\":33554432}}}}}},\"operations\":{{\"bind-existing\":{{" ++
            "\"op\":\"atomic-transaction\",\"effects\":[{{\"op\":\"bind-existing\"," ++
            "\"slot\":\"events\",\"input\":\"event\"}}]}}}}," ++
            "\"projections\":{{\"rows\":{{\"slot\":\"events\",\"pipeline\":[" ++
            "{{\"op\":\"sort\",\"keys\":[{{\"path\":\"/score\",\"order\":\"descending\"}}," ++
            "{{\"path\":\"/group\",\"order\":\"ascending\"}}]}}," ++
            "{{\"op\":\"select\",\"fields\":{{\"id\":\"/id\",\"score\":\"/score\"," ++
            "\"group\":\"/group\",\"payload\":\"/payload\"}}}}," ++
            "{{\"op\":\"limit\",\"count\":{d}}}]}}}},\"diagnostics\":{{}}," ++
            "\"bounds\":{{\"max_input_bytes\":4096,\"max_store_bytes\":33554432," ++
            "\"max_records\":16384,\"max_output_bytes\":2097152," ++
            "\"max_diagnostics\":16,\"max_reducer_states\":16}}}}",
        .{@max(limit, 1)},
    );
}

fn ledgerBytes(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    for (0..count) |index| {
        try writeRow(&out.writer, index);
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn score(index: usize) usize {
    return (index * 4051) % 4096;
}

fn writeRow(writer: *std.Io.Writer, index: usize) !void {
    const payload = [_]u8{'a'} ** 1024;
    try writer.print(
        "{{\"id\":{d},\"score\":{d},\"group\":{d},\"payload\":\"{s}\"}}",
        .{ index, score(index), (index / 4096) % 2, payload },
    );
}

fn expectedLedger(allocator: std.mem.Allocator, case: Case) ![]u8 {
    const indices = try allocator.alloc(usize, case.rows);
    defer allocator.free(indices);
    for (indices, 0..) |*value, index| value.* = index;
    std.mem.sort(usize, indices, {}, struct {
        fn less(_: void, left: usize, right: usize) bool {
            if (score(left) != score(right)) return score(left) > score(right);
            const lg = (left / 4096) % 2;
            const rg = (right / 4096) % 2;
            if (lg != rg) return lg < rg;
            return left < right;
        }
    }.less);
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (indices[0..@min(case.rows, case.limit)], 0..) |index, row| {
        if (row > 0) try out.writer.writeByte(',');
        try writeRow(&out.writer, index);
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn traceBytes(allocator: std.mem.Allocator, turns: usize) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll(
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-07-26T10:00:00Z\"," ++
            "\"payload\":{\"id\":\"optimization-session\",\"model\":\"gpt-test\"," ++
            "\"cwd\":\"/optimization\"}}\n",
    );
    for (0..turns) |turn| try writeTurn(&out.writer, turn);
    return out.toOwnedSlice();
}

fn writeTurn(writer: *std.Io.Writer, turn: usize) !void {
    try writer.print(
        "{{\"type\":\"event_msg\",\"timestamp\":\"2026-07-26T10:00:01Z\"," ++
            "\"payload\":{{\"type\":\"task_started\",\"turn_id\":\"turn-{d}\"}}}}\n" ++
            "{{\"type\":\"event_msg\",\"timestamp\":\"2026-07-26T10:00:02Z\"," ++
            "\"payload\":{{\"type\":\"user_message\",\"message\":\"Inspect item {d}\"}}}}\n",
        .{ turn, turn },
    );
    for (0..4) |call| try writeCall(writer, turn, call);
    try writer.print(
        "{{\"type\":\"event_msg\",\"timestamp\":\"2026-07-26T10:00:08Z\"," ++
            "\"payload\":{{\"type\":\"agent_message\",\"message\":\"Completed item {d}\"}}}}\n" ++
            "{{\"type\":\"event_msg\",\"timestamp\":\"2026-07-26T10:00:09Z\"," ++
            "\"payload\":{{\"type\":\"task_complete\",\"turn_id\":\"turn-{d}\"}}}}\n",
        .{ turn, turn },
    );
}

fn writeCall(writer: *std.Io.Writer, turn: usize, call: usize) !void {
    try writer.print(
        "{{\"type\":\"response_item\",\"timestamp\":\"2026-07-26T10:00:03Z\"," ++
            "\"payload\":{{\"type\":\"function_call\",\"name\":\"exec_command\"," ++
            "\"call_id\":\"call-{d}-{d}\"," ++
            "\"arguments\":\"{{\\\"cmd\\\":\\\"echo item\\\"}}\"}}}}\n" ++
            "{{\"type\":\"response_item\",\"timestamp\":\"2026-07-26T10:00:04Z\"," ++
            "\"payload\":{{\"type\":\"function_call_output\",\"call_id\":\"call-{d}-{d}\"," ++
            "\"output\":\"item completed successfully\"}}}}\n",
        .{ turn, call, turn, call },
    );
}

fn execute(allocator: std.mem.Allocator, case: Case, fixture: *Fixture) !Output {
    if (case.rows > 0) {
        const plans = &fixture.plans.?;
        return .{ .ledger = try ledger.projection.execute(
            allocator,
            &plans.definition_plan,
            &plans.storage_plan.?,
            if (plans.protocol_plan) |*value| value else null,
            &plans.projection_plan.?,
            "rows",
            fixture.root,
            &fixture.parameters.?,
        ) };
    }
    var reader = std.Io.Reader.fixed(fixture.bytes);
    const options = trace.TraceParseOptions{};
    const parsed = if (case.summary)
        try trace.parseSessionSummaryTraceReader(
            allocator,
            "/optimization/rollout.jsonl",
            &reader,
            0,
            options,
        )
    else
        try trace.parseSessionTraceReader(
            allocator,
            "/optimization/rollout.jsonl",
            &reader,
            0,
            options,
        );
    return .{ .trace = parsed };
}

fn outputDigest(
    allocator: std.mem.Allocator,
    case: Case,
    fixture: *const Fixture,
    output: Output,
) ![64]u8 {
    if (output == .ledger) {
        try validateLedgerOutput(allocator, fixture.expected, output.ledger.payload);
        return digest(output.ledger.payload);
    }
    const value = output.trace;
    if (value.session.turn_count != case.turns or value.warnings.items.len != 0) {
        return error.IncorrectTraceOutput;
    }
    if (!case.summary and
        (value.turns.items.len != case.turns or value.tools.items.len != case.turns * 4))
    {
        return error.IncorrectTraceOutput;
    }
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{
        .session = value.session,
        .turns = value.turns.items,
        .tools = value.tools.items,
        .graph_edges = value.graph_edges.items,
        .occurrences = value.occurrences.items,
        .token_events = value.token_events.items,
        .warnings = value.warnings.items,
    }, .{});
    defer allocator.free(bytes);
    return digest(bytes);
}

fn validateLedgerOutput(
    allocator: std.mem.Allocator,
    expected: []const u8,
    actual: []const u8,
) !void {
    var left = try std.json.parseFromSlice(std.json.Value, allocator, expected, .{});
    defer left.deinit();
    var right = try std.json.parseFromSlice(std.json.Value, allocator, actual, .{
        .duplicate_field_behavior = .@"error",
    });
    defer right.deinit();
    if (right.value != .array or right.value.array.items.len != left.value.array.items.len) {
        return error.IncorrectLedgerOutput;
    }
    for (left.value.array.items, right.value.array.items) |expected_row, actual_row| {
        if (actual_row != .object or actual_row.object.count() != 4) {
            return error.IncorrectLedgerOutput;
        }
        for ([_][]const u8{ "id", "score", "group", "payload" }) |field| {
            const field_left = expected_row.object.get(field).?;
            const field_right = actual_row.object.get(field) orelse
                return error.IncorrectLedgerOutput;
            const equal = switch (field_left) {
                .integer => |value| field_right == .integer and field_right.integer == value,
                .string => |value| field_right == .string and
                    std.mem.eql(u8, value, field_right.string),
                else => return error.IncorrectLedgerOutput,
            };
            if (!equal) return error.IncorrectLedgerOutput;
        }
    }
}

fn measure(
    allocator: std.mem.Allocator,
    case: Case,
    fixture: *Fixture,
    expected_digest: [64]u8,
) !Metrics {
    var samples: [sample_count]u64 = undefined;
    var allocations: [sample_count]u64 = undefined;
    for (0..warmup_count + sample_count) |index| {
        var counting = core_perf.CountingAllocator.init(allocator);
        const start = std.Io.Clock.awake.now(io()).nanoseconds;
        var output = try execute(counting.allocator(), case, fixture);
        const elapsed = std.Io.Clock.awake.now(io()).nanoseconds - start;
        defer output.deinit(counting.allocator());
        const calls = counting.stats.totalCalls();
        const actual_digest = try outputDigest(allocator, case, fixture, output);
        if (!std.mem.eql(u8, &expected_digest, &actual_digest)) {
            return error.NonDeterministicOutput;
        }
        if (index < warmup_count) continue;
        samples[index - warmup_count] = @intCast(@max(elapsed, 1));
        allocations[index - warmup_count] = calls;
    }
    return .{
        .samples_ns = samples,
        .p50_ns = percentile(samples, 50),
        .p95_ns = percentile(samples, 95),
        .p50_alloc_calls = percentile(allocations, 50),
    };
}

fn percentile(values: [sample_count]u64, percent: usize) u64 {
    var sorted = values;
    std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));
    return sorted[((sample_count - 1) * percent) / 100];
}

fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn workloadDigest(fixture: Fixture) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(fixture.definition);
    hash.update("\n");
    hash.update(fixture.bytes);
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

fn writeOracle(case: Case, fixture: Fixture, output_digest: [64]u8) !void {
    var stdout = std.Io.File.stdout().writer(io(), &.{});
    try stdout.interface.print(
        "{{\"case_id\":\"{s}\",\"workload_sha256\":\"{s}\",\"output_sha256\":\"{s}\"}}\n",
        .{ case.id, workloadDigest(fixture), output_digest },
    );
}

fn writeArtifact(
    allocator: std.mem.Allocator,
    case: Case,
    fixture: Fixture,
    metrics: Metrics,
    output_digest: [64]u8,
) !void {
    const machine = try machineName(allocator);
    defer allocator.free(machine);
    const directory = try std.fs.path.join(
        allocator,
        &.{ ".perf-local", machine, "baselines", case.binary },
    );
    defer allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(io(), directory);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ directory, case.id });
    defer allocator.free(path);
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{
        .schema_version = 1,
        .machine_id = machine,
        .git_sha = "unknown",
        .zig_version = builtin.zig_version_string,
        .binary = case.binary,
        .case_id = case.id,
        .case_kind = "native",
        .tolerance_pct = 3.0,
        .workload_sha256 = workloadDigest(fixture),
        .output_sha256 = output_digest,
        .metrics = metrics,
        .compare_status = "capture",
        .compare_detail = "captured",
    }, .{ .emit_strings_as_arrays = false });
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = bytes });
}

fn machineName(allocator: std.mem.Allocator) ![]u8 {
    var hostname: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const full = try std.posix.gethostname(&hostname);
    const host = full[0 .. std.mem.indexOfScalar(u8, full, '.') orelse full.len];
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-zig{s}", .{
        if (builtin.os.tag == .macos) "darwin" else @tagName(builtin.os.tag),
        if (builtin.cpu.arch == .aarch64) "arm64" else @tagName(builtin.cpu.arch),
        host,
        builtin.zig_version_string,
    });
}

test "optimization Ledger oracle checks fields and row order independently" {
    const expected =
        "[{\"id\":1,\"score\":9,\"group\":0,\"payload\":\"a\"}," ++
        "{\"id\":2,\"score\":8,\"group\":1,\"payload\":\"b\"}]";
    try validateLedgerOutput(std.testing.allocator, expected, expected);
    const mutations = [_][]const u8{
        "[]",
        "[{\"id\":1,\"score\":9,\"group\":0}]",
        "[{\"id\":1,\"score\":9,\"group\":0,\"payload\":\"a\",\"extra\":0}]",
        "[{\"id\":2,\"score\":8,\"group\":1,\"payload\":\"b\"}," ++
            "{\"id\":1,\"score\":9,\"group\":0,\"payload\":\"a\"}]",
    };
    for (mutations) |actual| try std.testing.expectError(
        error.IncorrectLedgerOutput,
        validateLedgerOutput(std.testing.allocator, expected, actual),
    );
    for ([_][]const u8{ "id", "score", "group", "payload" }) |field| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            expected,
            .{},
        );
        defer parsed.deinit();
        parsed.value.array.items[0].object.getPtr(field).?.* = .null;
        const actual = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
        defer std.testing.allocator.free(actual);
        try std.testing.expectError(
            error.IncorrectLedgerOutput,
            validateLedgerOutput(std.testing.allocator, expected, actual),
        );
    }
}

test "optimization trace workload stays frozen across full and summary cases" {
    const full = try findCase("trace-full-1024");
    const summary = try findCase("trace-summary-1024");
    try std.testing.expectEqual(full.turns, summary.turns);
    const bytes = try traceBytes(std.testing.allocator, full.turns);
    defer std.testing.allocator.free(bytes);
    const definition = try definitionBytes(std.testing.allocator, 0);
    defer std.testing.allocator.free(definition);
    const fixture = Fixture{
        .bytes = bytes,
        .definition = definition,
        .root = undefined,
        .expected = undefined,
    };
    try std.testing.expectEqualStrings(
        "e7533393186f4b8b92cba4cda784bbab91f0171489515bed2f50e8e8f5aa99ed",
        &workloadDigest(fixture),
    );
    try std.testing.expectEqual(1 + 12 * 1024, std.mem.count(u8, bytes, "\n"));
}
