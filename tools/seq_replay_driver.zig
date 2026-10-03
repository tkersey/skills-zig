const std = @import("std");
const builtin = @import("builtin");
const core_perf = @import("core_perf");
const definition_core = @import("definition_core");
const seq_v1 = @import("seq_v1_core");

const case_id = "seq-observe-deep-batch8";
const binary = "seq";
const warmup_count: usize = 3;
const sample_count: usize = 30;
const batch_iterations: usize = 8;

const Metrics = struct {
    samples_ns: [sample_count]u64,
    p50_ns: u64,
    p95_ns: u64,
    p50_alloc_calls: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    try requireCaptureArgs(argv);
    const metrics = try measure(allocator);
    try writeArtifact(allocator, metrics);

    var stdout_writer = std.Io.File.stdout().writer(
        std.Io.Threaded.global_single_threaded.io(),
        &.{},
    );
    try stdout_writer.interface.print(
        "PASS\t{s}\tcaptured\n",
        .{case_id},
    );
}

fn requireCaptureArgs(argv: []const []const u8) !void {
    if (argv.len != 4 or
        !std.mem.eql(u8, argv[1], "capture") or
        !std.mem.eql(u8, argv[2], "--target") or
        !std.mem.eql(u8, argv[3], case_id))
    {
        return error.InvalidCommand;
    }
}

fn measure(allocator: std.mem.Allocator) !Metrics {
    var warmup_index: usize = 0;
    while (warmup_index < warmup_count) : (warmup_index += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var counting = core_perf.CountingAllocator.init(arena.allocator());
        try executeBatch(counting.allocator());
    }

    var samples_ns: [sample_count]u64 = undefined;
    var allocation_calls: [sample_count]u64 = undefined;
    for (0..sample_count) |sample_index| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var counting = core_perf.CountingAllocator.init(arena.allocator());
        const start_ns = std.Io.Clock.awake.now(
            std.Io.Threaded.global_single_threaded.io(),
        ).nanoseconds;
        try executeBatch(counting.allocator());
        samples_ns[sample_index] = @intCast(@max(
            std.Io.Clock.awake.now(
                std.Io.Threaded.global_single_threaded.io(),
            ).nanoseconds - start_ns,
            1,
        ));
        allocation_calls[sample_index] = counting.stats.totalCalls();
    }

    _ = allocator;
    return .{
        .samples_ns = samples_ns,
        .p50_ns = percentile(samples_ns, 50),
        .p95_ns = percentile(samples_ns, 95),
        .p50_alloc_calls = percentile(allocation_calls, 50),
    };
}

fn percentile(values: [sample_count]u64, percent: usize) u64 {
    var sorted = values;
    std.mem.sort(u64, sorted[0..], {}, struct {
        fn less(_: void, left: u64, right: u64) bool {
            return left < right;
        }
    }.less);
    return sorted[((sorted.len - 1) * percent) / 100];
}

fn executeBatch(allocator: std.mem.Allocator) !void {
    for (0..batch_iterations) |_| try executeSeqObserve(allocator);
}

fn executeSeqObserve(allocator: std.mem.Allocator) !void {
    const cwd = try std.process.currentPathAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        allocator,
    );
    defer allocator.free(cwd);
    const definition_root = try std.fs.path.join(
        allocator,
        &.{ cwd, "apps/seq/src/v1/fixtures" },
    );
    defer allocator.free(definition_root);
    const projection_names = [_][]const u8{"rows"};
    var plans = try seq_v1.compiled_plan.load(
        allocator,
        definition_root,
        "message-observation.json",
        .{ .projection_names = &projection_names },
        "1.0.0",
        "seq-source-adapter/v1",
        .{},
    );
    defer plans.deinit(allocator);
    const parameter_inputs = [_]definition_core.parameters.Input{.{
        .name = "needle",
        .raw_value = "failure",
    }};
    var parameters = try definition_core.parameters.bind(
        allocator,
        &plans.definition_plan.parameter_declarations,
        &parameter_inputs,
    );
    defer parameters.deinit(allocator);
    var program = try seq_v1.execution.compile(
        allocator,
        &plans.definition_plan,
        &plans.native_plan,
        &parameters,
        "rows",
    );
    defer program.deinit(allocator);
    const output_cells = try std.math.mul(
        usize,
        program.max_rows,
        program.output_field_indices.len,
    );
    const output = try allocator.alloc(seq_v1.execution.Value, output_cells);
    defer allocator.free(output);
    const trace_path = try std.fs.path.join(
        allocator,
        &.{ definition_root, "rollout.jsonl" },
    );
    defer allocator.free(trace_path);
    var observation = try seq_v1.trace_adapter.observeFile(
        allocator,
        &program,
        trace_path,
        .{
            .max_input_bytes = plans.definition_plan.bounds.max_input_bytes,
        },
        output,
    );
    defer observation.deinit(allocator);
    if (observation.result.row_count != 1 or
        observation.metrics.bytes_read == 0)
    {
        return error.InvalidPerfObservation;
    }
}

fn writeArtifact(allocator: std.mem.Allocator, metrics: Metrics) !void {
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const baseline_dir = try std.fs.path.join(
        allocator,
        &.{ ".perf-local", machine_name, "baselines", binary },
    );
    defer allocator.free(baseline_dir);
    try std.Io.Dir.cwd().createDirPath(
        std.Io.Threaded.global_single_threaded.io(),
        baseline_dir,
    );
    const artifact_name = case_id ++ ".json";
    const artifact_path = try std.fs.path.join(
        allocator,
        &.{ baseline_dir, artifact_name },
    );
    defer allocator.free(artifact_path);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.print(
        "{{\"schema_version\":1,\"machine_id\":\"{s}\"," ++
            "\"git_sha\":\"unknown\",\"zig_version\":\"{s}\"," ++
            "\"binary\":\"{s}\",\"case_id\":\"{s}\"," ++
            "\"case_kind\":\"native\",\"tolerance_pct\":3.00," ++
            "\"metrics\":{{\"samples_ns\":[",
        .{ machine_name, builtin.zig_version_string, binary, case_id },
    );
    for (metrics.samples_ns, 0..) |sample, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{d}", .{sample});
    }
    try writer.print(
        "],\"p50_ns\":{d},\"p95_ns\":{d}," ++
            "\"p50_alloc_calls\":{d}}}," ++
            "\"compare_status\":\"capture\"," ++
            "\"compare_detail\":\"captured\"}}\n",
        .{ metrics.p50_ns, metrics.p95_ns, metrics.p50_alloc_calls },
    );
    try std.Io.Dir.cwd().writeFile(
        std.Io.Threaded.global_single_threaded.io(),
        .{ .sub_path = artifact_path, .data = output.written() },
    );
}

fn currentMachineDirName(allocator: std.mem.Allocator) ![]u8 {
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host_full = try std.posix.gethostname(&host_buf);
    const host = host_full[0 .. std.mem.indexOfScalar(u8, host_full, '.') orelse
        host_full.len];
    return allocator.print("{s}-{s}-{s}-zig{s}", .{
        switch (builtin.target.os.tag) {
            .macos => "darwin",
            else => @tagName(builtin.target.os.tag),
        },
        switch (builtin.target.cpu.arch) {
            .aarch64 => "arm64",
            else => @tagName(builtin.target.cpu.arch),
        },
        host,
        builtin.zig_version_string,
    });
}
