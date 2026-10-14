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
    var dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
    defer dir.close(init.io);
    const metrics = try measure(init.io, dir, allocator);
    try writeArtifact(init.io, dir, allocator, metrics);

    var stdout_writer = std.Io.File.stdout().writer(
        init.io,
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

fn measure(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator) !Metrics {
    var warmup_index: usize = 0;
    while (warmup_index < warmup_count) : (warmup_index += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var counting = core_perf.CountingAllocator.init(arena.allocator());
        try executeBatch(io, dir, counting.allocator());
    }

    var samples_ns: [sample_count]u64 = undefined;
    var allocation_calls: [sample_count]u64 = undefined;
    for (0..sample_count) |sample_index| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var counting = core_perf.CountingAllocator.init(arena.allocator());
        const start_ns = std.Io.Clock.awake.now(io).nanoseconds;
        try executeBatch(io, dir, counting.allocator());
        samples_ns[sample_index] = @intCast(@max(
            std.Io.Clock.awake.now(io).nanoseconds - start_ns,
            1,
        ));
        allocation_calls[sample_index] = counting.stats.totalCalls();
    }

    _ = allocator;
    const sorted_times = sortedSamples(samples_ns);
    const sorted_allocations = sortedSamples(allocation_calls);
    return .{
        .samples_ns = samples_ns,
        .p50_ns = percentile(&sorted_times, 50),
        .p95_ns = percentile(&sorted_times, 95),
        .p50_alloc_calls = percentile(&sorted_allocations, 50),
    };
}

// Drivers also compile against archived core_perf modules that predate the
// shared summary API. Keep this fixed-size working copy local to the driver.
fn sortedSamples(values: [sample_count]u64) [sample_count]u64 {
    var sorted = values;
    std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));
    return sorted;
}

fn percentile(sorted: *const [sample_count]u64, percent: usize) u64 {
    return sorted[((sample_count - 1) * percent) / 100];
}

fn executeBatch(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator) !void {
    for (0..batch_iterations) |_| try executeSeqObserve(io, dir, allocator);
}

fn executeSeqObserve(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator) !void {
    const cwd = try dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    const definition_root = try std.fs.path.join(allocator, &.{ cwd, "apps/seq/src/v1/fixtures" });
    defer allocator.free(definition_root);
    var plans = try loadObservePlans(io, dir, allocator, definition_root);
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
    var observation = if (comptime @typeInfo(
        @TypeOf(seq_v1.trace_adapter.observeFile),
    ).@"fn".param_types.len == 7)
        try seq_v1.trace_adapter.observeFile(
            io,
            dir,
            allocator,
            &program,
            trace_path,
            .{
                .max_input_bytes = plans.definition_plan.bounds.max_input_bytes,
            },
            output,
        )
    else
        try seq_v1.trace_adapter.observeFile(
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

fn loadObservePlans(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    definition_root: []const u8,
) !seq_v1.compiled_plan.PlanSet {
    const projection_names = [_][]const u8{"rows"};
    // The active driver is overlaid into archived product snapshots. Keep
    // their original API usable without reintroducing ambient authority in
    // current Seq modules or changing the frozen historical driver source.
    return if (comptime @typeInfo(
        @TypeOf(seq_v1.compiled_plan.load),
    ).@"fn".param_types.len == 8)
        try seq_v1.compiled_plan.load(
            .init(io, dir),
            allocator,
            definition_root,
            "message-observation.json",
            .{ .projection_names = &projection_names },
            "1.0.0",
            "seq-source-adapter/v1",
            .{},
        )
    else
        try seq_v1.compiled_plan.load(
            allocator,
            definition_root,
            "message-observation.json",
            .{ .projection_names = &projection_names },
            "1.0.0",
            "seq-source-adapter/v1",
            .{},
        );
}

fn writeArtifact(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    metrics: Metrics,
) !void {
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const baseline_dir = try std.fs.path.join(
        allocator,
        &.{ ".perf-local", machine_name, "baselines", binary },
    );
    defer allocator.free(baseline_dir);
    try dir.createDirPath(io, baseline_dir);
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
    try dir.writeFile(
        io,
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

test "Seq replay driver summary sorts once without changing captured order" {
    var samples: [sample_count]u64 = undefined;
    for (&samples, 0..) |*sample, index| sample.* = @intCast(sample_count - index);
    const captured = samples;
    const sorted = sortedSamples(samples);
    try std.testing.expectEqual(@as(u64, 15), percentile(&sorted, 50));
    try std.testing.expectEqual(@as(u64, 28), percentile(&sorted, 95));
    try std.testing.expectEqualSlices(u64, &captured, &samples);
}

test "Seq replay driver artifact uses supplied directory and I/O" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    const metrics: Metrics = .{
        .samples_ns = @splat(1),
        .p50_ns = 1,
        .p95_ns = 1,
        .p50_alloc_calls = 1,
    };
    try writeArtifact(io, first.dir, allocator, metrics);
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const artifact_path = try std.fs.path.join(allocator, &.{
        ".perf-local", machine_name, "baselines", binary, case_id ++ ".json",
    });
    defer allocator.free(artifact_path);
    const first_bytes = try first.dir.readFileAlloc(io, artifact_path, allocator, .limited(4096));
    defer allocator.free(first_bytes);
    try std.testing.expectError(
        error.FileNotFound,
        second.dir.readFileAlloc(io, artifact_path, allocator, .limited(4096)),
    );
    try writeArtifact(io, second.dir, allocator, metrics);
    const second_bytes = try second.dir.readFileAlloc(io, artifact_path, allocator, .limited(4096));
    defer allocator.free(second_bytes);
    try std.testing.expectEqualSlices(u8, first_bytes, second_bytes);

    const Canceled = struct {
        fn createDirPath(
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: std.Io.Dir.Permissions,
        ) std.Io.Dir.CreateDirPathError!std.Io.Dir.CreatePathStatus {
            return error.Canceled;
        }
    };
    var vtable = io.vtable.*;
    vtable.dirCreateDirPath = Canceled.createDirPath;
    const canceled_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(
        error.Canceled,
        writeArtifact(canceled_io, first.dir, allocator, metrics),
    );
}
