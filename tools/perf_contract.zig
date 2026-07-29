const std = @import("std");

pub const CoverageKind = enum {
    deep,
    shallow,
    excluded,
    missing,

    pub fn asString(self: CoverageKind) []const u8 {
        return switch (self) {
            .deep => "deep",
            .shallow => "shallow",
            .excluded => "excluded",
            .missing => "missing",
        };
    }
};

pub const MeasurementMode = enum {
    latency_only,
    latency_alloc,

    pub fn asString(self: MeasurementMode) []const u8 {
        return switch (self) {
            .latency_only => "latency_only",
            .latency_alloc => "latency_alloc",
        };
    }
};

pub const CaseKind = enum {
    subprocess,
    driver,
    native,

    pub fn asString(self: CaseKind) []const u8 {
        return switch (self) {
            .subprocess => "subprocess",
            .driver => "driver",
            .native => "native",
        };
    }
};

pub const CommandCoverage = struct {
    family: []const u8,
    coverage: CoverageKind,
    reason: []const u8 = "",
};

pub const DataSurface = struct {
    name: []const u8,
    coverage: CoverageKind,
    reason: []const u8 = "",
};

pub const CaseDescriptor = struct {
    case_id: []const u8,
    binary: []const u8,
    family: []const u8,
    case_kind: CaseKind,
    measurement_mode: MeasurementMode,
    compat_case: bool = false,
};

pub const BinaryManifest = struct {
    binary: []const u8,
    coverages: []const CommandCoverage,
    datasets: []const DataSurface = &.{},
    cases: []const CaseDescriptor,
};

pub const CompareSummaryRow = struct {
    case_id: []const u8,
    binary: []const u8,
    status: []const u8,
    detail: []const u8,
};

pub fn writeManifestJson(
    allocator: std.mem.Allocator,
    stdout: anytype,
    manifests: []const BinaryManifest,
) !void {
    _ = allocator;
    const writer = stdout;
    try writer.writeAll("{\"binaries\":[");
    for (manifests, 0..) |manifest, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{{\"binary\":\"{s}\",\"coverages\":[", .{manifest.binary});
        for (manifest.coverages, 0..) |coverage, cidx| {
            if (cidx > 0) try writer.writeByte(',');
            try writer.print(
                "{{\"family\":\"{s}\",\"coverage\":\"{s}\",\"reason\":",
                .{ coverage.family, coverage.coverage.asString() },
            );
            try writeJsonString(writer, coverage.reason);
            try writer.writeByte('}');
        }
        try writer.writeAll("],\"datasets\":[");
        for (manifest.datasets, 0..) |dataset, didx| {
            if (didx > 0) try writer.writeByte(',');
            try writer.print(
                "{{\"name\":\"{s}\",\"coverage\":\"{s}\",\"reason\":",
                .{ dataset.name, dataset.coverage.asString() },
            );
            try writeJsonString(writer, dataset.reason);
            try writer.writeByte('}');
        }
        try writer.writeAll("],\"cases\":[");
        for (manifest.cases, 0..) |case_desc, case_idx| {
            if (case_idx > 0) try writer.writeByte(',');
            try writer.print(
                "{{\"case_id\":\"{s}\",\"binary\":\"{s}\",\"family\":\"{s}\",\"case_kind\":\"{s}\",\"measurement_mode\":\"{s}\",\"compat_case\":{s}}}",
                .{
                    case_desc.case_id,
                    case_desc.binary,
                    case_desc.family,
                    case_desc.case_kind.asString(),
                    case_desc.measurement_mode.asString(),
                    if (case_desc.compat_case) "true" else "false",
                },
            );
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("]}\n");
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}
