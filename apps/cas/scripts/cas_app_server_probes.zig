const std = @import("std");
const contract = @import("cas_app_server_contract");
const proxy = @import("cas_proxy_client");

pub const ProbeStatus = enum { passed, failed, unavailable, not_applicable };

pub const ProbeRow = struct {
    id: []const u8,
    requirement: []const u8,
    status: []const u8,
    failureCode: ?[]const u8,
    failureHint: ?[]const u8,
};

pub const Witnesses = struct {
    schema_only: bool = false,
    lifecycle_passed: bool = false,
    lifecycle_failure_code: ?[]const u8 = null,
    lifecycle_failure_hint: ?[]const u8 = null,
    handler_coverage_passed: bool = false,
    retry_passed: bool = false,
};

pub const ProbeReport = struct {
    rows: [contract.behavioral_probe_descriptors.len]ProbeRow,
    compatible: bool,
};

pub fn buildReport(
    profile: contract.Profile,
    selection: contract.ProbeSelection,
    witnesses: Witnesses,
) ProbeReport {
    var rows: [contract.behavioral_probe_descriptors.len]ProbeRow = undefined;
    var compatible = true;
    for (contract.behavioral_probe_descriptors, 0..) |descriptor, index| {
        if (witnesses.schema_only) {
            rows[index] = row(descriptor.id, .not_applicable, .not_applicable, null, "schema-only inspection");
            continue;
        }
        const requirement = contract.probeRequirement(profile, selection, descriptor.id) orelse unreachable;
        if (requirement == .not_applicable) {
            rows[index] = row(descriptor.id, requirement, .not_applicable, null, null);
            continue;
        }

        const status: ProbeStatus = if (std.mem.eql(u8, descriptor.id, "initialize-lifecycle"))
            if (witnesses.lifecycle_passed) .passed else .failed
        else if (descriptor.transport != null or descriptor.code_mode_host)
            if (witnesses.lifecycle_passed) .passed else .failed
        else if (std.mem.eql(u8, descriptor.id, "server-request-coverage"))
            if (witnesses.handler_coverage_passed) .passed else .failed
        else if (std.mem.eql(u8, descriptor.id, "bounded-overload-retry"))
            if (witnesses.retry_passed) .passed else .failed
        else
            .unavailable;

        const failure_code: ?[]const u8 = switch (status) {
            .passed, .not_applicable => null,
            .unavailable => "probe_unavailable",
            .failed => if (std.mem.eql(u8, descriptor.id, "initialize-lifecycle") or descriptor.transport != null or descriptor.code_mode_host)
                witnesses.lifecycle_failure_code orelse "initialize_lifecycle_failed"
            else if (std.mem.eql(u8, descriptor.id, "server-request-coverage"))
                "server_request_coverage_failed"
            else
                "bounded_overload_retry_failed",
        };
        const failure_hint: ?[]const u8 = switch (status) {
            .passed, .not_applicable => null,
            .unavailable => "required behavioral probe is not implemented",
            .failed => if (std.mem.eql(u8, descriptor.id, "initialize-lifecycle") or descriptor.transport != null or descriptor.code_mode_host)
                witnesses.lifecycle_failure_hint orelse "app-server initialize lifecycle did not complete"
            else if (std.mem.eql(u8, descriptor.id, "server-request-coverage"))
                "contract policies and proxy server-request handlers are not in exact parity"
            else
                "bounded overload retry kernel did not satisfy its deterministic bounds",
        };
        rows[index] = row(descriptor.id, requirement, status, failure_code, failure_hint);
        if (status != .passed) compatible = false;
    }
    return .{ .rows = rows, .compatible = compatible };
}

pub fn retryKernelProbe(allocator: std.mem.Allocator) bool {
    const policy: proxy.OverloadRetryPolicy = .{};
    proxy.validateOverloadRetryPolicy(policy) catch return false;
    var prior: u32 = 0;
    for (0..policy.max_retries) |index| {
        const retry_index: u32 = @intCast(index);
        const first = proxy.overloadRetryDelayMs(policy, retry_index, 0x5eed);
        const second = proxy.overloadRetryDelayMs(policy, retry_index, 0x5eed);
        if (first != second or first < policy.base_delay_ms or first > policy.max_delay_ms) return false;
        if (index != 0 and first < prior) return false;
        prior = first;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, "{\"code\":-32001,\"message\":\"overloaded\"}", .{}) catch return false;
    defer parsed.deinit();
    return proxy.isStructuredOverloadError(parsed.value);
}

fn row(
    id: []const u8,
    requirement: contract.ProbeRequirement,
    status: ProbeStatus,
    failure_code: ?[]const u8,
    failure_hint: ?[]const u8,
) ProbeRow {
    return .{
        .id = id,
        .requirement = switch (requirement) {
            .required => "required",
            .not_applicable => "not_applicable",
        },
        .status = switch (status) {
            .passed => "passed",
            .failed => "failed",
            .unavailable => "unavailable",
            .not_applicable => "not_applicable",
        },
        .failureCode = failure_code,
        .failureHint = failure_hint,
    };
}

test "probe report preserves baseline order and core common witnesses" {
    const report = buildReport(.core, .{ .transport = .stdio }, .{
        .lifecycle_passed = true,
        .handler_coverage_passed = true,
        .retry_passed = true,
    });
    try std.testing.expect(report.compatible);
    try std.testing.expectEqual(contract.behavioral_probe_descriptors.len, report.rows.len);
    for (contract.behavioral_probe_descriptors, report.rows) |descriptor, probe_row| {
        try std.testing.expectEqualStrings(descriptor.id, probe_row.id);
    }
    try std.testing.expectEqualStrings("passed", report.rows[0].status);
    try std.testing.expectEqualStrings("passed", report.rows[1].status);
    try std.testing.expectEqualStrings("not_applicable", report.rows[2].status);
}

test "unimplemented required profile probe fails closed" {
    const report = buildReport(.review, .{ .transport = .stdio }, .{
        .lifecycle_passed = true,
        .handler_coverage_passed = true,
        .retry_passed = true,
    });
    try std.testing.expect(!report.compatible);
    try std.testing.expectEqualStrings("structured-review", report.rows[13].id);
    try std.testing.expectEqualStrings("unavailable", report.rows[13].status);
    try std.testing.expectEqualStrings("probe_unavailable", report.rows[13].failureCode.?);
}

test "retry kernel witness is deterministic and bounded" {
    try std.testing.expect(retryKernelProbe(std.testing.allocator));
}
