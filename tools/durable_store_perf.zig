const std = @import("std");
const builtin = @import("builtin");
const durable_store = @import("durable_store");

const Io = std.Io.Threaded.global_single_threaded;
const default_fixture_bytes: usize = 60 * 1024 * 1024;
const rounds: usize = 3;
const target_name = std.fmt.comptimePrint("{s}-{s}-{s}", .{
    @tagName(builtin.target.cpu.arch),
    @tagName(builtin.target.os.tag),
    @tagName(builtin.target.abi),
});
const fixture_line =
    "{\"schema\":\"event/v1\",\"sequence\":1," ++
    "\"payload\":\"abcdefghijklmnopqrstuvwxyz\"}\n";

const Cli = struct {
    fixture_bytes: usize = default_fixture_bytes,
    baseline_path: ?[]const u8 = null,
    strict: bool = false,
};

const Baseline = struct {
    scan_elapsed_ns: u64,
    scan_peak_live_bytes: u64,
    append_elapsed_ns: u64,
    append_peak_live_bytes: u64,
};

const Round = struct {
    elapsed_ns: u64,
    peak_live_bytes: u64,
    record_count: usize,
};

const Measurements = struct {
    target: []const u8,
    cpu_model: []const u8,
    zig_version: []const u8,
    optimize_mode: []const u8,
    fixture_sha256: [64]u8,
    actual_bytes: usize,
    record_count: usize,
    scan_elapsed_ns: u64,
    scan_peak_live_bytes: u64,
    append_elapsed_ns: u64,
    append_peak_live_bytes: u64,
};

const Fixture = struct {
    actual_bytes: usize,
    sha256: [64]u8,
};

const PeakAllocator = struct {
    child: std.mem.Allocator,
    live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,

    fn init(child: std.mem.Allocator) PeakAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *PeakAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn addLive(self: *PeakAllocator, bytes: usize) void {
        self.live_bytes += @intCast(bytes);
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
    }

    fn removeLive(self: *PeakAllocator, bytes: usize) void {
        self.live_bytes -= @intCast(bytes);
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        const memory = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.addLive(len);
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        if (new_len >= memory.len) {
            self.addLive(new_len - memory.len);
        } else {
            self.removeLive(memory.len - new_len);
        }
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        if (new_len >= memory.len) {
            self.addLive(new_len - memory.len);
        } else {
            self.removeLive(memory.len - new_len);
        }
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        self.removeLive(memory.len);
        self.child.rawFree(memory, alignment, return_address);
    }
};

pub fn main(init: std.process.Init) !void {
    durable_store.installRuntimeIo(init.io);
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const cli = parseCli(argv) catch return error.InvalidArguments;

    const fixture_dir = try std.fmt.allocPrint(
        allocator,
        ".perf-local/durable-store-{d}",
        .{std.Io.Clock.awake.now(Io.io()).nanoseconds},
    );
    defer allocator.free(fixture_dir);
    try std.Io.Dir.cwd().createDirPath(Io.io(), fixture_dir);
    defer cleanupFixture(fixture_dir);

    const fixture_path = try std.fs.path.join(
        allocator,
        &.{ fixture_dir, "events.jsonl" },
    );
    defer allocator.free(fixture_path);
    const measurements = try measureFixture(fixture_path, cli.fixture_bytes);
    try writeReport(allocator, cli, measurements);
}

fn cleanupFixture(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(Io.io(), path) catch |err| {
        std.debug.print(
            "durable-store performance fixture cleanup failed: {s}\n",
            .{@errorName(err)},
        );
    };
}

fn measureFixture(fixture_path: []const u8, fixture_bytes: usize) !Measurements {
    const fixture = try writeFixture(fixture_path, fixture_bytes);
    const actual_bytes = fixture.actual_bytes;

    var samples: [rounds]Round = undefined;
    for (&samples) |*sample| sample.* = try measureScan(fixture_path, actual_bytes);
    var append_samples: [rounds]Round = undefined;
    for (&append_samples) |*sample| {
        _ = try writeFixture(fixture_path, fixture_bytes);
        sample.* = try measureAppend(fixture_path, actual_bytes);
    }

    var elapsed: [rounds]u64 = undefined;
    var peaks: [rounds]u64 = undefined;
    var append_elapsed: [rounds]u64 = undefined;
    var append_peaks: [rounds]u64 = undefined;
    for (samples, 0..) |sample, index| {
        elapsed[index] = sample.elapsed_ns;
        peaks[index] = sample.peak_live_bytes;
        append_elapsed[index] = append_samples[index].elapsed_ns;
        append_peaks[index] = append_samples[index].peak_live_bytes;
    }
    std.mem.sort(u64, &elapsed, {}, comptime std.sort.asc(u64));
    std.mem.sort(u64, &peaks, {}, comptime std.sort.asc(u64));
    std.mem.sort(u64, &append_elapsed, {}, comptime std.sort.asc(u64));
    std.mem.sort(u64, &append_peaks, {}, comptime std.sort.asc(u64));

    return .{
        .target = target_name,
        .cpu_model = builtin.target.cpu.model.name,
        .zig_version = builtin.zig_version_string,
        .optimize_mode = @tagName(builtin.mode),
        .fixture_sha256 = fixture.sha256,
        .actual_bytes = actual_bytes,
        .record_count = samples[0].record_count,
        .scan_elapsed_ns = elapsed[rounds / 2],
        .scan_peak_live_bytes = peaks[rounds / 2],
        .append_elapsed_ns = append_elapsed[rounds / 2],
        .append_peak_live_bytes = append_peaks[rounds / 2],
    };
}

fn writeReport(
    allocator: std.mem.Allocator,
    cli: Cli,
    measurements: Measurements,
) !void {
    var stdout_writer = std.Io.File.stdout().writer(Io.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (cli.baseline_path) |baseline_path| {
        try writeMeasuredReport(allocator, stdout, baseline_path, cli, measurements);
    } else {
        try writeUnmeasuredReport(stdout, cli, measurements);
    }
}

fn writeMeasuredReport(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    baseline_path: []const u8,
    cli: Cli,
    measurements: Measurements,
) !void {
    const baseline = try loadBaseline(allocator, baseline_path, measurements);
    const scan_alloc_reduction = reductionPct(
        baseline.scan_peak_live_bytes,
        measurements.scan_peak_live_bytes,
    );
    const append_alloc_reduction = reductionPct(
        baseline.append_peak_live_bytes,
        measurements.append_peak_live_bytes,
    );
    const scan_latency_regression = regressionPct(
        baseline.scan_elapsed_ns,
        measurements.scan_elapsed_ns,
    );
    const append_latency_regression = regressionPct(
        baseline.append_elapsed_ns,
        measurements.append_elapsed_ns,
    );
    const passed = scan_alloc_reduction >= 80.0 and
        append_alloc_reduction >= 80.0 and
        scan_latency_regression <= 5.0 and
        append_latency_regression <= 10.0;
    try stdout.writeAll(
        "{\"schema\":\"durable-store-perf/v1\",\"route\":\"streaming\",",
    );
    try writeIdentity(stdout, measurements);
    const measured_format =
        "\"fixture_bytes\":{d},\"record_count\":{d},\"rounds\":{d}," ++
        "\"scan_p50_elapsed_ns\":{d},\"scan_p50_peak_live_bytes\":{d}," ++
        "\"append_p50_elapsed_ns\":{d},\"append_p50_peak_live_bytes\":{d}," ++
        "\"scan_alloc_reduction_pct\":{d:.2}," ++
        "\"append_alloc_reduction_pct\":{d:.2}," ++
        "\"scan_latency_regression_pct\":{d:.2}," ++
        "\"append_latency_regression_pct\":{d:.2}," ++
        "\"status\":\"{s}\",\"strict\":{s}}}\n";
    try stdout.print(
        measured_format,
        .{
            measurements.actual_bytes,
            measurements.record_count,
            rounds,
            measurements.scan_elapsed_ns,
            measurements.scan_peak_live_bytes,
            measurements.append_elapsed_ns,
            measurements.append_peak_live_bytes,
            scan_alloc_reduction,
            append_alloc_reduction,
            scan_latency_regression,
            append_latency_regression,
            if (passed) "pass" else "fail",
            if (cli.strict) "true" else "false",
        },
    );
    if (cli.strict and !passed) return error.PerformanceRegression;
}

fn writeUnmeasuredReport(
    stdout: *std.Io.Writer,
    cli: Cli,
    measurements: Measurements,
) !void {
    try stdout.writeAll(
        "{\"schema\":\"durable-store-perf/v1\",\"route\":\"streaming\",",
    );
    try writeIdentity(stdout, measurements);
    const unmeasured_format =
        "\"fixture_bytes\":{d},\"record_count\":{d},\"rounds\":{d}," ++
        "\"scan_p50_elapsed_ns\":{d},\"scan_p50_peak_live_bytes\":{d}," ++
        "\"append_p50_elapsed_ns\":{d},\"append_p50_peak_live_bytes\":{d}," ++
        "\"status\":\"unmeasured\",\"strict\":{s}}}\n";
    try stdout.print(
        unmeasured_format,
        .{
            measurements.actual_bytes,
            measurements.record_count,
            rounds,
            measurements.scan_elapsed_ns,
            measurements.scan_peak_live_bytes,
            measurements.append_elapsed_ns,
            measurements.append_peak_live_bytes,
            if (cli.strict) "true" else "false",
        },
    );
    if (cli.strict) return error.MissingBaseline;
}

fn writeIdentity(
    stdout: *std.Io.Writer,
    measurements: Measurements,
) !void {
    try stdout.writeAll("\"target\":");
    try std.json.Stringify.value(measurements.target, .{}, stdout);
    try stdout.writeAll(",\"cpu_model\":");
    try std.json.Stringify.value(measurements.cpu_model, .{}, stdout);
    try stdout.writeAll(",\"zig_version\":");
    try std.json.Stringify.value(measurements.zig_version, .{}, stdout);
    try stdout.writeAll(",\"optimize_mode\":");
    try std.json.Stringify.value(measurements.optimize_mode, .{}, stdout);
    try stdout.print(
        ",\"fixture_sha256\":\"{s}\",",
        .{&measurements.fixture_sha256},
    );
}

fn parseCli(argv: []const []const u8) !Cli {
    var cli = Cli{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        if (std.mem.eql(u8, argv[index], "--bytes")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            cli.fixture_bytes = try std.fmt.parseInt(usize, argv[index], 10);
            if (cli.fixture_bytes == 0) return error.InvalidBytes;
        } else if (std.mem.eql(u8, argv[index], "--baseline")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            cli.baseline_path = argv[index];
        } else if (std.mem.eql(u8, argv[index], "--strict")) {
            cli.strict = true;
        } else {
            return error.UnknownArgument;
        }
    }
    return cli;
}

fn writeFixture(path: []const u8, minimum_bytes: usize) !Fixture {
    var file = try std.Io.Dir.cwd().createFile(Io.io(), path, .{ .truncate = true });
    defer file.close(Io.io());
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var written: usize = 0;
    while (written < minimum_bytes) {
        try file.writeStreamingAll(Io.io(), fixture_line);
        hasher.update(fixture_line);
        written += fixture_line.len;
    }
    try file.sync(Io.io());
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return .{
        .actual_bytes = written,
        .sha256 = std.fmt.bytesToHex(digest, .lower),
    };
}

fn ignoreEvent(_: *anyopaque, _: durable_store.EventRecordView) !void {}

fn measureScan(path: []const u8, fixture_bytes: usize) !Round {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    var peak = PeakAllocator.init(debug_allocator.allocator());
    const allocator = peak.allocator();

    var backend = durable_store.PersistentEventStore.init(path);
    var ignored: u8 = 0;
    const started = std.Io.Clock.awake.now(Io.io()).nanoseconds;
    var summary = try backend.eventStore().scan(allocator, fixture_bytes, .{
        .context = &ignored,
        .visitFn = ignoreEvent,
    });
    const elapsed_ns: u64 = @intCast(@max(
        std.Io.Clock.awake.now(Io.io()).nanoseconds - started,
        1,
    ));
    const record_count = summary.record_count;
    summary.deinit(allocator);
    if (peak.live_bytes != 0) return error.BenchmarkLeak;
    return .{
        .elapsed_ns = elapsed_ns,
        .peak_live_bytes = peak.peak_live_bytes,
        .record_count = record_count,
    };
}

fn measureAppend(path: []const u8, fixture_bytes: usize) !Round {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    var peak = PeakAllocator.init(debug_allocator.allocator());
    const allocator = peak.allocator();

    const started = std.Io.Clock.awake.now(Io.io()).nanoseconds;
    try durable_store.appendLineAtomic(
        allocator,
        path,
        "{\"schema\":\"event/v1\",\"sequence\":2}",
        fixture_bytes + 1,
    );
    const elapsed_ns: u64 = @intCast(@max(
        std.Io.Clock.awake.now(Io.io()).nanoseconds - started,
        1,
    ));
    if (peak.live_bytes != 0) return error.BenchmarkLeak;
    return .{
        .elapsed_ns = elapsed_ns,
        .peak_live_bytes = peak.peak_live_bytes,
        .record_count = 0,
    };
}

fn loadBaseline(
    allocator: std.mem.Allocator,
    path: []const u8,
    measurements: Measurements,
) !Baseline {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        Io.io(),
        path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidBaseline,
    };
    return baselineFromObject(object, measurements);
}

fn baselineFromObject(
    object: std.json.ObjectMap,
    measurements: Measurements,
) !Baseline {
    try requireBaselineString(object, "schema", "durable-store-perf/v1");
    try requireBaselineString(object, "route", "aggregate");
    try requireBaselineString(object, "target", measurements.target);
    try requireBaselineString(object, "cpu_model", measurements.cpu_model);
    try requireBaselineString(object, "zig_version", measurements.zig_version);
    try requireBaselineString(object, "optimize_mode", measurements.optimize_mode);
    try requireBaselineString(
        object,
        "fixture_sha256",
        &measurements.fixture_sha256,
    );
    try requireBaselineUsize(object, "fixture_bytes", measurements.actual_bytes);
    try requireBaselineUsize(object, "record_count", measurements.record_count);
    try requireBaselineUsize(object, "rounds", rounds);
    return .{
        .scan_elapsed_ns = try baselineU64(object, "scan_p50_elapsed_ns"),
        .scan_peak_live_bytes = try baselineU64(object, "scan_p50_peak_live_bytes"),
        .append_elapsed_ns = try baselineU64(object, "append_p50_elapsed_ns"),
        .append_peak_live_bytes = try baselineU64(object, "append_p50_peak_live_bytes"),
    };
}

fn requireBaselineString(
    object: std.json.ObjectMap,
    name: []const u8,
    expected: []const u8,
) !void {
    const value = object.get(name) orelse return error.InvalidBaseline;
    const observed = switch (value) {
        .string => |string| string,
        else => return error.InvalidBaseline,
    };
    if (!std.mem.eql(u8, expected, observed)) return error.InvalidBaseline;
}

fn requireBaselineUsize(
    object: std.json.ObjectMap,
    name: []const u8,
    expected: usize,
) !void {
    const value = object.get(name) orelse return error.InvalidBaseline;
    const integer = switch (value) {
        .integer => |observed| observed,
        else => return error.InvalidBaseline,
    };
    if (integer <= 0) return error.InvalidBaseline;
    const observed = std.math.cast(usize, integer) orelse return error.InvalidBaseline;
    if (observed != expected) return error.InvalidBaseline;
}

fn baselineU64(object: std.json.ObjectMap, name: []const u8) !u64 {
    const value = object.get(name) orelse return error.InvalidBaseline;
    return switch (value) {
        .integer => |integer| if (integer > 0) @intCast(integer) else error.InvalidBaseline,
        else => error.InvalidBaseline,
    };
}

fn reductionPct(baseline: u64, current: u64) f64 {
    return (@as(f64, @floatFromInt(baseline)) - @as(f64, @floatFromInt(current))) /
        @as(f64, @floatFromInt(baseline)) * 100.0;
}

fn regressionPct(baseline: u64, current: u64) f64 {
    return (@as(f64, @floatFromInt(current)) - @as(f64, @floatFromInt(baseline))) /
        @as(f64, @floatFromInt(baseline)) * 100.0;
}

const test_fixture_sha256 =
    "0000000000000000000000000000000000000000000000000000000000000000";

fn testMeasurements() Measurements {
    return .{
        .target = "test-target",
        .cpu_model = "test-cpu",
        .zig_version = "test-zig",
        .optimize_mode = "ReleaseFast",
        .fixture_sha256 = test_fixture_sha256.*,
        .actual_bytes = 96,
        .record_count = 3,
        .scan_elapsed_ns = 1,
        .scan_peak_live_bytes = 1,
        .append_elapsed_ns = 1,
        .append_peak_live_bytes = 1,
    };
}

fn baselineJsonAlloc(
    allocator: std.mem.Allocator,
    target: []const u8,
    cpu_model: []const u8,
    zig_version: []const u8,
    optimize_mode: []const u8,
    fixture_sha256: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"durable-store-perf/v1\",\"route\":\"aggregate\"," ++
            "\"target\":\"{s}\",\"cpu_model\":\"{s}\",\"zig_version\":\"{s}\"," ++
            "\"optimize_mode\":\"{s}\",\"fixture_sha256\":\"{s}\"," ++
            "\"fixture_bytes\":96,\"record_count\":3,\"rounds\":3," ++
            "\"scan_p50_elapsed_ns\":100,\"scan_p50_peak_live_bytes\":200," ++
            "\"append_p50_elapsed_ns\":300,\"append_p50_peak_live_bytes\":400}}",
        .{ target, cpu_model, zig_version, optimize_mode, fixture_sha256 },
    );
}

test "performance baseline identity is exact" {
    const valid = try baselineJsonAlloc(
        std.testing.allocator,
        "test-target",
        "test-cpu",
        "test-zig",
        "ReleaseFast",
        test_fixture_sha256,
    );
    defer std.testing.allocator.free(valid);
    const measurements = testMeasurements();
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        valid,
        .{},
    );
    defer parsed.deinit();
    const baseline = try baselineFromObject(parsed.value.object, measurements);
    try std.testing.expectEqual(@as(u64, 100), baseline.scan_elapsed_ns);
    try std.testing.expectEqual(@as(u64, 400), baseline.append_peak_live_bytes);
}

test "performance baseline rejects mismatched workload metadata" {
    const identity =
        "\"target\":\"test-target\",\"cpu_model\":\"test-cpu\"," ++
        "\"zig_version\":\"test-zig\",\"optimize_mode\":\"ReleaseFast\"," ++
        "\"fixture_sha256\":\"" ++ test_fixture_sha256 ++ "\",";
    const metrics =
        "\"scan_p50_elapsed_ns\":1," ++
        "\"scan_p50_peak_live_bytes\":1," ++
        "\"append_p50_elapsed_ns\":1," ++
        "\"append_p50_peak_live_bytes\":1";
    const invalid = [_][]const u8{
        "{\"schema\":\"other\",\"route\":\"aggregate\"," ++
            identity ++ "\"fixture_bytes\":96,\"record_count\":3,\"rounds\":3," ++ metrics ++ "}",
        "{\"schema\":\"durable-store-perf/v1\",\"route\":\"streaming\"," ++
            identity ++ "\"fixture_bytes\":96,\"record_count\":3,\"rounds\":3," ++ metrics ++ "}",
        "{\"schema\":\"durable-store-perf/v1\",\"route\":\"aggregate\"," ++
            identity ++ "\"fixture_bytes\":97,\"record_count\":3,\"rounds\":3," ++ metrics ++ "}",
        "{\"schema\":\"durable-store-perf/v1\",\"route\":\"aggregate\"," ++
            identity ++ "\"fixture_bytes\":96,\"record_count\":4,\"rounds\":3," ++ metrics ++ "}",
        "{\"schema\":\"durable-store-perf/v1\",\"route\":\"aggregate\"," ++
            identity ++ "\"fixture_bytes\":96,\"record_count\":3,\"rounds\":4," ++ metrics ++ "}",
        "{" ++ metrics ++ "}",
    };
    const measurements = testMeasurements();
    for (invalid) |text| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            text,
            .{},
        );
        defer parsed.deinit();
        try std.testing.expectError(
            error.InvalidBaseline,
            baselineFromObject(parsed.value.object, measurements),
        );
    }
}

test "performance baseline rejects mismatched environment and fixture identity" {
    const mismatch = [_]struct {
        target: []const u8 = "test-target",
        cpu_model: []const u8 = "test-cpu",
        zig_version: []const u8 = "test-zig",
        optimize_mode: []const u8 = "ReleaseFast",
        fixture_sha256: []const u8 = test_fixture_sha256,
    }{
        .{ .target = "other-target" },
        .{ .cpu_model = "other-cpu" },
        .{ .zig_version = "other-zig" },
        .{ .optimize_mode = "Debug" },
        .{
            .fixture_sha256 = "1111111111111111111111111111111111111111111111111111111111111111",
        },
    };
    const measurements = testMeasurements();
    for (mismatch) |identity| {
        const text = try baselineJsonAlloc(
            std.testing.allocator,
            identity.target,
            identity.cpu_model,
            identity.zig_version,
            identity.optimize_mode,
            identity.fixture_sha256,
        );
        defer std.testing.allocator.free(text);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            text,
            .{},
        );
        defer parsed.deinit();
        try std.testing.expectError(
            error.InvalidBaseline,
            baselineFromObject(parsed.value.object, measurements),
        );
    }
}
