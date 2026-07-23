const std = @import("std");
const durable_store = @import("durable_store");

const Io = std.Io.Threaded.global_single_threaded;
const default_fixture_bytes: usize = 60 * 1024 * 1024;
const rounds: usize = 3;
const fixture_line = "{\"schema\":\"event/v1\",\"sequence\":1,\"payload\":\"abcdefghijklmnopqrstuvwxyz\"}\n";

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

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
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
        const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse return null;
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
    defer std.Io.Dir.cwd().deleteTree(Io.io(), fixture_dir) catch {};

    const fixture_path = try std.fs.path.join(allocator, &.{ fixture_dir, "events.jsonl" });
    defer allocator.free(fixture_path);
    const actual_bytes = try writeFixture(fixture_path, cli.fixture_bytes);

    var samples: [rounds]Round = undefined;
    for (&samples) |*sample| sample.* = try measureScan(fixture_path, actual_bytes);
    var append_samples: [rounds]Round = undefined;
    for (&append_samples) |*sample| {
        _ = try writeFixture(fixture_path, cli.fixture_bytes);
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

    var stdout_writer = std.Io.File.stdout().writer(Io.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (cli.baseline_path) |baseline_path| {
        const baseline = try loadBaseline(allocator, baseline_path);
        const scan_alloc_reduction = reductionPct(baseline.scan_peak_live_bytes, peaks[rounds / 2]);
        const append_alloc_reduction = reductionPct(baseline.append_peak_live_bytes, append_peaks[rounds / 2]);
        const scan_latency_regression = regressionPct(baseline.scan_elapsed_ns, elapsed[rounds / 2]);
        const append_latency_regression = regressionPct(baseline.append_elapsed_ns, append_elapsed[rounds / 2]);
        const passed = scan_alloc_reduction >= 80.0 and
            append_alloc_reduction >= 80.0 and
            scan_latency_regression <= 5.0 and
            append_latency_regression <= 10.0;
        try stdout.print(
            "{{\"schema\":\"durable-store-perf/v1\",\"route\":\"streaming\",\"fixture_bytes\":{d},\"record_count\":{d},\"rounds\":{d},\"scan_p50_elapsed_ns\":{d},\"scan_p50_peak_live_bytes\":{d},\"append_p50_elapsed_ns\":{d},\"append_p50_peak_live_bytes\":{d},\"scan_alloc_reduction_pct\":{d:.2},\"append_alloc_reduction_pct\":{d:.2},\"scan_latency_regression_pct\":{d:.2},\"append_latency_regression_pct\":{d:.2},\"status\":\"{s}\",\"strict\":{s}}}\n",
            .{
                actual_bytes,
                samples[0].record_count,
                rounds,
                elapsed[rounds / 2],
                peaks[rounds / 2],
                append_elapsed[rounds / 2],
                append_peaks[rounds / 2],
                scan_alloc_reduction,
                append_alloc_reduction,
                scan_latency_regression,
                append_latency_regression,
                if (passed) "pass" else "fail",
                if (cli.strict) "true" else "false",
            },
        );
        if (cli.strict and !passed) return error.PerformanceRegression;
    } else {
        try stdout.print(
            "{{\"schema\":\"durable-store-perf/v1\",\"route\":\"streaming\",\"fixture_bytes\":{d},\"record_count\":{d},\"rounds\":{d},\"scan_p50_elapsed_ns\":{d},\"scan_p50_peak_live_bytes\":{d},\"append_p50_elapsed_ns\":{d},\"append_p50_peak_live_bytes\":{d},\"status\":\"unmeasured\",\"strict\":{s}}}\n",
            .{
                actual_bytes,
                samples[0].record_count,
                rounds,
                elapsed[rounds / 2],
                peaks[rounds / 2],
                append_elapsed[rounds / 2],
                append_peaks[rounds / 2],
                if (cli.strict) "true" else "false",
            },
        );
        if (cli.strict) return error.MissingBaseline;
    }
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

fn writeFixture(path: []const u8, minimum_bytes: usize) !usize {
    var file = try std.Io.Dir.cwd().createFile(Io.io(), path, .{ .truncate = true });
    defer file.close(Io.io());
    var written: usize = 0;
    while (written < minimum_bytes) {
        try file.writeStreamingAll(Io.io(), fixture_line);
        written += fixture_line.len;
    }
    try file.sync(Io.io());
    return written;
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

fn loadBaseline(allocator: std.mem.Allocator, path: []const u8) !Baseline {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(Io.io(), path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidBaseline,
    };
    return .{
        .scan_elapsed_ns = try baselineU64(object, "scan_p50_elapsed_ns"),
        .scan_peak_live_bytes = try baselineU64(object, "scan_p50_peak_live_bytes"),
        .append_elapsed_ns = try baselineU64(object, "append_p50_elapsed_ns"),
        .append_peak_live_bytes = try baselineU64(object, "append_p50_peak_live_bytes"),
    };
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
