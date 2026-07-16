const std = @import("std");

const Manifest = struct {
    schema: []const u8,
    specification_section: []const u8,
    cases: []const Case,
};

const Case = struct {
    case_id: u8,
    source: []const u8,
    test_name: []const u8,
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

const StoreCoverageManifest = struct {
    schema: []const u8,
    specification_section: []const u8,
    expected_case_count: u8,
    expected_backend_lanes: []const []const u8,
    cases: []const StoreCoverageCase,
};

const StoreCoverageCase = struct {
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
const store_coverage_bytes = @embedFile("conformance-store-coverage-v1.json");
const backend_probe_source_path = "apps/ledger/scripts/hylo.zig";
const backend_probe_prefix = "test \"HCTP backend observation ";
const expected_event_store_cases = [_]u8{ 2, 5, 11, 20, 57, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71 };

fn isKnownSourcePath(path: []const u8) bool {
    if (std.mem.eql(u8, path, "apps/ledger/scripts/hctp_conformance_registration.zig")) {
        return true;
    }
    if (std.mem.eql(u8, path, "apps/ledger/scripts/hctp_conformance_execution.zig")) {
        return true;
    }
    if (std.mem.eql(u8, path, "apps/ledger/scripts/hctp_conformance_grading.zig")) {
        return true;
    }
    if (std.mem.eql(u8, path, "apps/ledger/scripts/hctp_conformance_retrace_holdout.zig")) {
        return true;
    }
    return std.mem.eql(u8, path, "apps/ledger/scripts/hylo.zig");
}

fn validateCases(allocator: std.mem.Allocator, cases: []const Case) !void {
    if (cases.len != 71) return error.ConformanceCaseCountInvalid;

    var seen_cases = [_]bool{false} ** 72;
    for (cases, 0..) |entry, index| {
        if (entry.case_id < 1 or entry.case_id > 71) return error.ConformanceCaseOutOfRange;
        if (seen_cases[entry.case_id]) return error.ConformanceCaseDuplicate;
        seen_cases[entry.case_id] = true;

        if (!isKnownSourcePath(entry.source)) return error.ConformanceSourceUnresolvable;
        const source = std.Io.Dir.cwd().readFileAlloc(
            std.Io.Threaded.global_single_threaded.io(),
            entry.source,
            allocator,
            .limited(16 * 1024 * 1024),
        ) catch return error.ConformanceSourceUnresolvable;
        defer allocator.free(source);
        if (entry.test_name.len == 0) return error.ConformanceTestUnresolvable;

        for (cases[0..index]) |prior| {
            if (std.mem.eql(u8, prior.source, entry.source) and
                std.mem.eql(u8, prior.test_name, entry.test_name))
            {
                return error.ConformanceTestDuplicate;
            }
        }

        const case_label = try std.fmt.allocPrint(allocator, "case {d}:", .{entry.case_id});
        defer allocator.free(case_label);
        const section_label = try std.fmt.allocPrint(allocator, "36.{d} ", .{entry.case_id});
        defer allocator.free(section_label);
        if (std.mem.indexOf(u8, entry.test_name, case_label) == null and
            std.mem.indexOf(u8, entry.test_name, section_label) == null)
        {
            return error.ConformanceCaseLabelMismatch;
        }

        const declaration = try std.fmt.allocPrint(allocator, "test \"{s}\" {{", .{entry.test_name});
        defer allocator.free(declaration);
        if (std.mem.count(u8, source, declaration) != 1) {
            return error.ConformanceTestUnresolvable;
        }
    }

    for (seen_cases[1..]) |seen| {
        if (!seen) return error.ConformanceCaseMissing;
    }
}

fn parseManifest(allocator: std.mem.Allocator) !std.json.Parsed(Manifest) {
    return std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}

fn parseStoreCoverage(allocator: std.mem.Allocator) !std.json.Parsed(StoreCoverageManifest) {
    return std.json.parseFromSlice(StoreCoverageManifest, allocator, store_coverage_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}

fn isExpectedEventStoreCase(case_id: u8) bool {
    for (expected_event_store_cases) |expected| {
        if (case_id == expected) return true;
    }
    return false;
}

fn validateBackendProbeDeclarations(
    allocator: std.mem.Allocator,
    coverage: StoreCoverageManifest,
    source: []const u8,
) !void {
    if (std.mem.count(u8, source, backend_probe_prefix) != expected_event_store_cases.len + 2) {
        return error.ConformanceBackendProbeCountInvalid;
    }
    inline for (.{
        "HCTP backend observation reset",
        "HCTP backend observation absence probe",
    }) |name| {
        const declaration = try std.fmt.allocPrint(allocator, "test \"{s}\" {{", .{name});
        defer allocator.free(declaration);
        if (std.mem.count(u8, source, declaration) != 1) {
            return error.ConformanceBackendProbeDeclarationInvalid;
        }
    }
    for (expected_event_store_cases) |case_id| {
        const declaration = try std.fmt.allocPrint(
            allocator,
            "test \"HCTP backend observation case {d} probe\" {{",
            .{case_id},
        );
        defer allocator.free(declaration);
        if (std.mem.count(u8, source, declaration) != 1) {
            return error.ConformanceBackendProbeDeclarationInvalid;
        }
        if (coverage.cases[case_id - 1].store_class != .event_store) {
            return error.ConformanceBackendProbeCoverageMismatch;
        }
    }
    for (coverage.cases) |entry| {
        if (std.mem.startsWith(u8, entry.test_name, "HCTP backend observation ") or
            std.mem.startsWith(u8, entry.owner_test_name, "HCTP backend observation "))
        {
            return error.ConformanceBackendProbeIncludedInCaseMapping;
        }
        if (entry.store_class == .event_store and !isExpectedEventStoreCase(entry.case_id)) {
            return error.ConformanceBackendProbeCoverageMismatch;
        }
    }
}

fn validateStoreCoverage(
    allocator: std.mem.Allocator,
    manifest: Manifest,
    coverage: StoreCoverageManifest,
) !void {
    if (!std.mem.eql(u8, coverage.schema, "hylo-hctp-conformance-store-coverage/v1")) {
        return error.ConformanceStoreCoverageSchemaInvalid;
    }
    if (!std.mem.eql(u8, coverage.specification_section, manifest.specification_section)) {
        return error.ConformanceStoreCoverageSectionMismatch;
    }
    if (coverage.expected_case_count != 71 or coverage.cases.len != manifest.cases.len) {
        return error.ConformanceStoreCoverageCountInvalid;
    }
    if (coverage.expected_backend_lanes.len != 2 or
        !std.mem.eql(u8, coverage.expected_backend_lanes[0], "memory") or
        !std.mem.eql(u8, coverage.expected_backend_lanes[1], "persistent"))
    {
        return error.ConformanceStoreCoverageBackendLanesInvalid;
    }

    var store_independent_count: usize = 0;
    var event_store_count: usize = 0;
    var selected_backend_count: usize = 0;
    var intrinsic_both_count: usize = 0;
    for (coverage.cases, manifest.cases) |entry, mapped| {
        if (entry.case_id != mapped.case_id or
            !std.mem.eql(u8, entry.source, mapped.source) or
            !std.mem.eql(u8, entry.test_name, mapped.test_name))
        {
            return error.ConformanceStoreCoverageMappingMismatch;
        }
        if (entry.rationale.len == 0) return error.ConformanceStoreCoverageRationaleMissing;

        switch (entry.store_class) {
            .store_independent => {
                store_independent_count += 1;
                if (entry.persistent_reload_required or
                    entry.backend_mode != .not_applicable or
                    !std.mem.eql(u8, entry.owner_source, entry.source) or
                    !std.mem.eql(u8, entry.owner_test_name, entry.test_name) or
                    std.mem.eql(u8, entry.owner_source, "apps/ledger/scripts/hylo.zig"))
                {
                    return error.ConformanceStoreIndependentClassificationInvalid;
                }
            },
            .event_store => {
                event_store_count += 1;
                if (!entry.persistent_reload_required or
                    !std.mem.eql(u8, entry.owner_source, "apps/ledger/scripts/hylo.zig"))
                {
                    return error.ConformanceEventStoreClassificationInvalid;
                }
                if (entry.case_id == 68) {
                    if (entry.backend_mode != .intrinsic_both) {
                        return error.ConformanceEventStoreBackendModeInvalid;
                    }
                    intrinsic_both_count += 1;
                } else {
                    if (entry.backend_mode != .selected) {
                        return error.ConformanceEventStoreBackendModeInvalid;
                    }
                    selected_backend_count += 1;
                }
            },
        }

        const owner_source = std.Io.Dir.cwd().readFileAlloc(
            std.Io.Threaded.global_single_threaded.io(),
            entry.owner_source,
            allocator,
            .limited(16 * 1024 * 1024),
        ) catch return error.ConformanceOwnerSourceUnresolvable;
        defer allocator.free(owner_source);
        const declaration = try std.fmt.allocPrint(allocator, "test \"{s}\" {{", .{entry.owner_test_name});
        defer allocator.free(declaration);
        if (std.mem.count(u8, owner_source, declaration) != 1) {
            return error.ConformanceOwnerTestUnresolvable;
        }
    }

    if (store_independent_count != 54 or event_store_count != 17 or
        selected_backend_count != 16 or intrinsic_both_count != 1)
    {
        return error.ConformanceStoreCoverageClassCountInvalid;
    }
    const probe_source = std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        backend_probe_source_path,
        allocator,
        .limited(16 * 1024 * 1024),
    ) catch return error.ConformanceBackendProbeSourceUnresolvable;
    defer allocator.free(probe_source);
    try validateBackendProbeDeclarations(allocator, coverage, probe_source);
}

test "HCTP-v1 Section 36 conformance manifest is complete and executable" {
    var parsed = try parseManifest(std.testing.allocator);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hylo-hctp-conformance-manifest/v1", parsed.value.schema);
    try std.testing.expectEqualStrings("HCTP-v1 Section 36", parsed.value.specification_section);
    try validateCases(std.testing.allocator, parsed.value.cases);
}

test "HCTP-v1 conformance manifest rejects missing duplicate out-of-range and unresolvable mappings" {
    var parsed = try parseManifest(std.testing.allocator);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 71), parsed.value.cases.len);

    var cases: [71]Case = undefined;
    @memcpy(cases[0..], parsed.value.cases);

    try std.testing.expectError(
        error.ConformanceCaseCountInvalid,
        validateCases(std.testing.allocator, cases[0..70]),
    );

    cases[70].case_id = cases[69].case_id;
    try std.testing.expectError(
        error.ConformanceCaseDuplicate,
        validateCases(std.testing.allocator, &cases),
    );
    cases[70] = parsed.value.cases[70];

    cases[0].case_id = 0;
    try std.testing.expectError(
        error.ConformanceCaseOutOfRange,
        validateCases(std.testing.allocator, &cases),
    );
    cases[0] = parsed.value.cases[0];

    cases[0].source = "apps/ledger/scripts/missing-conformance-source.zig";
    try std.testing.expectError(
        error.ConformanceSourceUnresolvable,
        validateCases(std.testing.allocator, &cases),
    );
    cases[0] = parsed.value.cases[0];

    cases[0].test_name = "HCTP Section 36 case 1: missing executable declaration";
    try std.testing.expectError(
        error.ConformanceTestUnresolvable,
        validateCases(std.testing.allocator, &cases),
    );
}

test "HCTP-v1 Section 36 store coverage is complete and owner-bound" {
    var parsed_manifest = try parseManifest(std.testing.allocator);
    defer parsed_manifest.deinit();
    var parsed_coverage = try parseStoreCoverage(std.testing.allocator);
    defer parsed_coverage.deinit();

    try validateStoreCoverage(
        std.testing.allocator,
        parsed_manifest.value,
        parsed_coverage.value,
    );
}

test "HCTP-v1 store coverage rejects semantic and EventStore classification drift" {
    var parsed_manifest = try parseManifest(std.testing.allocator);
    defer parsed_manifest.deinit();
    var parsed_coverage = try parseStoreCoverage(std.testing.allocator);
    defer parsed_coverage.deinit();

    var cases: [71]StoreCoverageCase = undefined;
    @memcpy(cases[0..], parsed_coverage.value.cases);
    var coverage = parsed_coverage.value;
    coverage.cases = &cases;

    cases[0].test_name = "drifted mapping";
    try std.testing.expectError(
        error.ConformanceStoreCoverageMappingMismatch,
        validateStoreCoverage(std.testing.allocator, parsed_manifest.value, coverage),
    );
    cases[0] = parsed_coverage.value.cases[0];

    cases[0].store_class = .event_store;
    try std.testing.expectError(
        error.ConformanceEventStoreClassificationInvalid,
        validateStoreCoverage(std.testing.allocator, parsed_manifest.value, coverage),
    );
    cases[0] = parsed_coverage.value.cases[0];

    cases[1].persistent_reload_required = false;
    try std.testing.expectError(
        error.ConformanceEventStoreClassificationInvalid,
        validateStoreCoverage(std.testing.allocator, parsed_manifest.value, coverage),
    );
}

test "HCTP-v1 backend probe declarations reject missing and duplicate case probes" {
    var parsed_coverage = try parseStoreCoverage(std.testing.allocator);
    defer parsed_coverage.deinit();
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        backend_probe_source_path,
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const missing = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        source,
        "test \"HCTP backend observation case 2 probe\" {",
        "test \"HCTP backend observation case 200 probe\" {",
    );
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(
        error.ConformanceBackendProbeDeclarationInvalid,
        validateBackendProbeDeclarations(std.testing.allocator, parsed_coverage.value, missing),
    );

    const duplicate = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        source,
        "test \"HCTP backend observation case 5 probe\" {",
        "test \"HCTP backend observation case 2 probe\" {",
    );
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(
        error.ConformanceBackendProbeDeclarationInvalid,
        validateBackendProbeDeclarations(std.testing.allocator, parsed_coverage.value, duplicate),
    );
}
