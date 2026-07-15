const builtin = @import("builtin");
const std = @import("std");

pub const std_options: std.Options = .{
    .logFn = log,
};

const StoreClass = enum {
    store_independent,
    event_store,
};

const BackendMode = enum {
    not_applicable,
    selected,
    intrinsic_both,
};

const RequestedBackend = enum {
    memory,
    persistent,
};

const Manifest = struct {
    schema: []const u8,
    specification_section: []const u8,
    cases: []const ManifestCase,
};

const ManifestCase = struct {
    case_id: u8,
    source: []const u8,
    test_name: []const u8,
};

const Coverage = struct {
    schema: []const u8,
    specification_section: []const u8,
    expected_case_count: u8,
    expected_backend_lanes: []const []const u8,
    cases: []const Case,
};

const Case = struct {
    case_id: u8,
    source: []const u8,
    test_name: []const u8,
    store_class: StoreClass,
    owner_source: []const u8,
    owner_test_name: []const u8,
    backend_mode: BackendMode,
    persistent_reload_required: bool,
    rationale: []const u8,
};

const manifest_bytes = @embedFile("conformance-v1.json");
const coverage_bytes = @embedFile("conformance-store-coverage-v1.json");
const hylo_source = "apps/ledger/scripts/hylo.zig";
const reset_probe_test = "HCTP backend observation reset";
const absence_probe_test = "HCTP backend observation absence probe";
const carrier_source = "apps/ledger/scripts/hctp_conformance_backend.zig";
const carrier_test = "HCTP EventStore carrier bridge preserves ordered payloads across memory and persistent reload";
const expected_event_store_cases = [_]u8{ 2, 5, 11, 20, 57, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71 };

var log_error_count: usize = 0;

pub fn main(init: std.process.Init.Minimal) !void {
    @disableInstrumentation();
    std.testing.environ = init.environ;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const requested = try requiredBackend(init.environ, arena);

    var manifest_parsed = try std.json.parseFromSlice(Manifest, arena, manifest_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer manifest_parsed.deinit();
    var coverage_parsed = try std.json.parseFromSlice(Coverage, arena, coverage_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer coverage_parsed.deinit();
    const manifest = manifest_parsed.value;
    const coverage = coverage_parsed.value;
    try validateCoverage(manifest, coverage);
    const reset_probe = try findUniqueTest(arena, hylo_source, reset_probe_test);
    const absence_probe = try findUniqueTest(arena, hylo_source, absence_probe_test);

    var semantic_tests_run: usize = 0;
    var store_independent_count: usize = 0;
    var event_store_owner_count: usize = 0;
    var selected_backend_owner_count: usize = 0;
    var intrinsic_both_owner_count: usize = 0;
    var additional_owner_tests: usize = 0;
    var persistent_reload_count: usize = 0;

    for (coverage.cases) |entry| {
        const mapped = try findUniqueTest(arena, entry.source, entry.test_name);
        const mapped_is_owner = std.mem.eql(u8, entry.owner_test_name, entry.test_name) and
            std.mem.eql(u8, entry.owner_source, entry.source);
        const mapped_probe = if (entry.store_class == .event_store and mapped_is_owner)
            try findCaseProbe(arena, entry.case_id)
        else
            absence_probe;
        try runOne(reset_probe, mapped, mapped_probe, entry.case_id, "semantic");
        semantic_tests_run += 1;

        switch (entry.store_class) {
            .store_independent => store_independent_count += 1,
            .event_store => {
                event_store_owner_count += 1;
                switch (entry.backend_mode) {
                    .not_applicable => return error.EventStoreBackendModeInvalid,
                    .selected => selected_backend_owner_count += 1,
                    .intrinsic_both => intrinsic_both_owner_count += 1,
                }
                if (entry.backend_mode == .intrinsic_both or requested == .persistent) {
                    persistent_reload_count += 1;
                }
                if (!mapped_is_owner) {
                    const owner = try findUniqueTest(arena, entry.owner_source, entry.owner_test_name);
                    const owner_probe = try findCaseProbe(arena, entry.case_id);
                    try runOne(
                        reset_probe,
                        owner,
                        owner_probe,
                        entry.case_id,
                        "event-store-owner",
                    );
                    additional_owner_tests += 1;
                }
            },
        }
    }

    const carrier = try findUniqueTest(arena, carrier_source, carrier_test);
    try runOne(reset_probe, carrier, absence_probe, 0, "event-store-carrier");

    if (semantic_tests_run != 71 or
        store_independent_count != 54 or
        event_store_owner_count != 17 or
        selected_backend_owner_count != 16 or
        intrinsic_both_owner_count != 1 or
        additional_owner_tests != 2)
    {
        return error.ConformanceBackendCoverageIncomplete;
    }

    std.debug.print(
        "{{\"schema\":\"hylo-hctp-conformance-backend-result/v1\",\"backend\":\"{s}\",\"mapped_cases_executed\":{d},\"store_independent_cases_executed\":{d},\"event_store_owner_cases_executed\":{d},\"selected_backend_owner_cases\":{d},\"intrinsic_both_owner_cases\":{d},\"distinct_supporting_owner_tests\":{d},\"persistent_reload_verified_cases\":{d},\"carrier_equivalence_verified\":true}}\n",
        .{
            @tagName(requested),
            semantic_tests_run,
            store_independent_count,
            event_store_owner_count,
            selected_backend_owner_count,
            intrinsic_both_owner_count,
            additional_owner_tests,
            persistent_reload_count,
        },
    );
}

fn validateCoverage(manifest: Manifest, coverage: Coverage) !void {
    if (!std.mem.eql(u8, manifest.schema, "hylo-hctp-conformance-manifest/v1") or
        !std.mem.eql(u8, coverage.schema, "hylo-hctp-conformance-store-coverage/v1") or
        !std.mem.eql(u8, manifest.specification_section, coverage.specification_section) or
        coverage.expected_case_count != 71 or
        manifest.cases.len != 71 or
        coverage.cases.len != 71)
    {
        return error.ConformanceStoreCoverageInvalid;
    }
    if (coverage.expected_backend_lanes.len != 2 or
        !std.mem.eql(u8, coverage.expected_backend_lanes[0], "memory") or
        !std.mem.eql(u8, coverage.expected_backend_lanes[1], "persistent"))
    {
        return error.ConformanceBackendLanesInvalid;
    }
    for (manifest.cases, coverage.cases, 0..) |mapped, entry, index| {
        if (mapped.case_id != @as(u8, @intCast(index + 1)) or
            mapped.case_id != entry.case_id or
            !std.mem.eql(u8, mapped.source, entry.source) or
            !std.mem.eql(u8, mapped.test_name, entry.test_name))
        {
            return error.ConformanceStoreCoverageMappingMismatch;
        }
        if (std.mem.startsWith(u8, entry.test_name, "HCTP backend observation ") or
            std.mem.startsWith(u8, entry.owner_test_name, "HCTP backend observation "))
        {
            return error.ConformanceProbeIncludedInCaseMapping;
        }
        switch (entry.store_class) {
            .store_independent => if (entry.backend_mode != .not_applicable or
                entry.persistent_reload_required or
                !std.mem.eql(u8, entry.owner_source, entry.source) or
                !std.mem.eql(u8, entry.owner_test_name, entry.test_name))
            {
                return error.StoreIndependentOwnerInvalid;
            },
            .event_store => {
                if (!entry.persistent_reload_required or
                    !std.mem.eql(u8, entry.owner_source, "apps/ledger/scripts/hylo.zig") or
                    (entry.case_id == 68) != (entry.backend_mode == .intrinsic_both) or
                    (entry.case_id != 68 and entry.backend_mode != .selected))
                {
                    return error.EventStoreOwnerInvalid;
                }
            },
        }
    }
    for (expected_event_store_cases) |case_id| {
        if (coverage.cases[case_id - 1].store_class != .event_store) {
            return error.ConformanceBackendProbeMissing;
        }
    }
    for (coverage.cases) |entry| {
        if (entry.store_class == .event_store and !isExpectedEventStoreCase(entry.case_id)) {
            return error.ConformanceBackendProbeUnexpected;
        }
    }
}

fn requiredBackend(environ: std.process.Environ, allocator: std.mem.Allocator) !RequestedBackend {
    const backend = std.process.Environ.getAlloc(environ, allocator, "HCTP_CONFORMANCE_BACKEND") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.ConformanceBackendMissing,
        else => return err,
    };
    if (std.mem.eql(u8, backend, "memory")) return .memory;
    if (std.mem.eql(u8, backend, "persistent")) return .persistent;
    return error.ConformanceBackendInvalid;
}

fn findUniqueTest(
    allocator: std.mem.Allocator,
    source: []const u8,
    test_name: []const u8,
) !std.builtin.TestFn {
    const basename = std.fs.path.basename(source);
    const stem = std.fs.path.stem(basename);
    const expected = try std.fmt.allocPrint(allocator, "{s}.test.{s}", .{ stem, test_name });
    var found: ?std.builtin.TestFn = null;
    for (builtin.test_functions) |candidate| {
        if (!std.mem.eql(u8, candidate.name, expected)) continue;
        if (found != null) return error.ConformanceTestDuplicate;
        found = candidate;
    }
    return found orelse error.ConformanceTestMissing;
}

fn isExpectedEventStoreCase(case_id: u8) bool {
    for (expected_event_store_cases) |expected| {
        if (case_id == expected) return true;
    }
    return false;
}

fn findCaseProbe(allocator: std.mem.Allocator, case_id: u8) !std.builtin.TestFn {
    const test_name = try std.fmt.allocPrint(
        allocator,
        "HCTP backend observation case {d} probe",
        .{case_id},
    );
    return findUniqueTest(allocator, hylo_source, test_name);
}

fn runOne(
    reset_probe: std.builtin.TestFn,
    test_fn: std.builtin.TestFn,
    observation_probe: std.builtin.TestFn,
    case_id: u8,
    role: []const u8,
) !void {
    try runRaw(reset_probe, case_id, "backend-observation-reset");
    try runRaw(test_fn, case_id, role);
    try runRaw(observation_probe, case_id, "backend-observation-probe");
}

fn runRaw(
    test_fn: std.builtin.TestFn,
    case_id: u8,
    role: []const u8,
) !void {
    log_error_count = 0;
    std.testing.random_seed = 0;
    std.testing.log_level = .warn;
    std.testing.allocator_instance = .{};
    std.testing.io_instance = .init(std.testing.allocator, .{
        .environ = std.testing.environ,
    });

    const result = test_fn.func();
    std.testing.io_instance.deinit();
    const leaked = std.testing.allocator_instance.detectLeaks();
    std.testing.allocator_instance.deinitWithoutLeakChecks();
    if (leaked != 0) return error.ConformanceTestLeakedMemory;
    if (log_error_count != 0) return error.ConformanceTestLoggedError;

    result catch |err| {
        std.debug.print(
            "HCTP conformance case {d} {s} failed in {s}: {t}\n",
            .{ case_id, role, test_fn.name, err },
        );
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        return err;
    };
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_error_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(std.testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
