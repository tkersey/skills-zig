const std = @import("std");
const seq = @import("seq_v1_core");
const perf = @import("core_perf");
const definitions = @import("definition_core");
const Value = seq.execution.Value;
const sample_count = 30;

pub fn main(init: std.process.Init) !void {
    var writer = std.Io.File.stdout().writer(init.io, &.{});
    const out = &writer.interface;
    try out.writeAll("rows\twidth\tk\tdescending\tp50_ns\tp95_ns\talloc_calls\t" ++
        "allocated_bytes\tdigest\tsamples_ns\n");
    for ([_]usize{ 32, 16384 }) |rows| {
        for ([_]usize{ 3, 32 }) |width| {
            const input = try inputValues(init.gpa, rows, width);
            defer init.gpa.free(input);
            for ([_]usize{ 1, 10, 100, 1000, rows / 2, rows - 1, rows }) |limit| {
                if (limit > rows) continue;
                for ([_]bool{ false, true }) |descending| {
                    try measure(init, out, input, rows, width, limit, descending);
                }
            }
        }
    }
}

fn inputValues(allocator: std.mem.Allocator, rows: usize, width: usize) ![]Value {
    const input = try allocator.alloc(Value, rows * width);
    const tags = [_][]const u8{ "a", "b", "c" };
    for (0..rows) |row| {
        input[row * width] = if (row % 11 == 0)
            .null
        else
            .{ .integer = @intCast((row * 73) % 997) };
        input[row * width + 1] = .{ .string = tags[row % tags.len] };
        for (2..width) |column| {
            input[row * width + column] = .{ .integer = @intCast(row + column) };
        }
    }
    return input;
}

fn measure(
    init: std.process.Init,
    out: *std.Io.Writer,
    input: []Value,
    rows: usize,
    width: usize,
    limit: usize,
    descending: bool,
) !void {
    var timings: [sample_count]u64 = undefined;
    var expected_digest: ?u64 = null;
    var stats: perf.AllocStats = .{};
    for (0..sample_count + 3) |index| {
        var counting = perf.CountingAllocator.init(init.gpa);
        const allocator = counting.allocator();
        const start = std.Io.Clock.awake.now(init.io).nanoseconds;
        const result = try executeGraph(
            allocator,
            input,
            width,
            limit,
            descending,
        );
        const elapsed = std.Io.Clock.awake.now(init.io).nanoseconds - start;
        const digest = outputDigest(result);
        allocator.free(result);
        if (expected_digest) |expected| {
            if (digest != expected) return error.OutputChanged;
        } else expected_digest = digest;
        if (index >= 3) timings[index - 3] = @intCast(elapsed);
        stats = counting.stats;
    }
    const raw_samples = timings;
    std.mem.sort(u64, &timings, {}, std.sort.asc(u64));
    try out.print("{d}\t{d}\t{d}\t{}\t{d}\t{d}\t{d}\t{d}\t{x}\t{any}\n", .{
        rows,
        width,
        limit,
        descending,
        timings[14],
        timings[28],
        stats.totalCalls(),
        stats.totalRequestedBytes(),
        expected_digest.?,
        raw_samples,
    });
}

fn outputDigest(values: []const Value) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (values) |value| {
        const tag: u8 = @backingInt(std.meta.activeTag(value));
        hash.update(&.{tag});
        switch (value) {
            .integer => |number| hash.update(std.mem.asBytes(&number)),
            .string => |text| hash.update(text),
            .null => {},
            else => unreachable,
        }
    }
    return hash.final();
}

fn executeGraph(
    allocator: std.mem.Allocator,
    input: []Value,
    width: usize,
    limit: usize,
    descending: bool,
) ![]Value {
    var columns: [32]seq.plan.Column = undefined;
    var fields: [32]u16 = undefined;
    initializeColumns(columns[0..width], fields[0..width]);
    var keys = [_]seq.plan.SortKey{
        .{
            .field_index = 0,
            .direction = if (descending) .descending else .ascending,
            .nulls = .last,
        },
        .{ .field_index = 1, .direction = .ascending, .nulls = .first },
    };
    var stages = [_]seq.plan.Stage{
        .{
            .name = @constCast("source"),
            .source = null,
            .schema = .{ .columns = columns[0..width] },
            .operation = .{ .scan = .{ .relation = .sessions, .field_indices = fields[0..width] } },
        },
        .{
            .name = @constCast("ranked"),
            .source = .{ .stage = 0 },
            .schema = .{ .columns = columns[0..width] },
            .operation = .{ .top_k = .{ .keys = &keys, .limit = .{ .fixed = limit } } },
        },
    };
    var definition = graph_definition;
    definition.bounds.max_rows = input.len / width;
    const native = seq.plan.Plan{
        .stages = &stages,
        .projections = &.{},
        .max_rows = input.len / width,
        .max_output_bytes = input.len * @sizeOf(Value),
    };
    const bindings = definitions.parameters.Bindings{
        .items = &.{},
        .values_digest = @splat(0),
    };
    var scans = [_]seq.relation_graph.ScanInput{
        .{ .stage_index = 0, .table = .{ .values = input, .width = width } },
    };
    const result = try seq.relation_graph.executeTarget(
        allocator,
        allocator,
        &definition,
        &native,
        &bindings,
        .{},
        1,
        &scans,
    );
    errdefer allocator.free(result.table.values);
    if (result.source_rows != input.len / width or
        result.materialized_rows != input.len / width + @min(input.len / width, limit))
    {
        return error.ChangedRowCounts;
    }
    return result.table.values;
}

fn initializeColumns(columns: []seq.plan.Column, fields: []u16) void {
    for (columns, fields, 0..) |*column, *field, index| {
        column.* = .{
            .name = @constCast(column_names[index]),
            .kind = if (index == 1) .string else .integer,
            .nullable = index == 0,
        };
        field.* = @intCast(index);
    }
}

const column_names = [_][]const u8{
    "c0",  "c1",  "c2",  "c3",  "c4",  "c5",  "c6",  "c7",
    "c8",  "c9",  "c10", "c11", "c12", "c13", "c14", "c15",
    "c16", "c17", "c18", "c19", "c20", "c21", "c22", "c23",
    "c24", "c25", "c26", "c27", "c28", "c29", "c30", "c31",
};

const graph_steps = [_]seq.definition.Step{
    .{
        .operator = .scan,
        .output_name = @constCast("source"),
        .input_names = &.{},
        .canonical_config = @constCast("{}"),
    },
    .{
        .operator = .top_k,
        .output_name = @constCast("ranked"),
        .input_names = @constCast(&[_][]u8{@constCast("source")}),
        .canonical_config = @constCast("{}"),
    },
};

const graph_definition: seq.definition.Plan = .{
    .id = @constCast("optimization/graph-topk"),
    .closure_digest = @splat(0),
    .operator_mask = 0,
    .parameter_declarations = .{ .items = &.{}, .shape_digest = @splat(0) },
    .selector_mask = 0,
    .relations = &.{},
    .inputs = &.{},
    .steps = @constCast(&graph_steps),
    .projections = &.{},
    .bounds = .{
        .max_rows = 16384,
        .max_output_bytes = 32 * 1024 * 1024,
        .max_fold_states = 1,
        .max_input_bytes = 32 * 1024 * 1024,
        .max_graph_depth = 1,
        .max_graph_nodes = 2,
        .max_diagnostics = 1,
    },
};
