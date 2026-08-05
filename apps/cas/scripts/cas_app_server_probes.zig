const std = @import("std");
const contract = @import("cas_app_server_contract");
const proxy = @import("cas_proxy_client");

pub const ProbeStatus = enum { passed, failed, unavailable, not_applicable };

pub const LiveWitness = struct {
    status: ProbeStatus = .unavailable,
    failure_code: ?[]const u8 = "probe_unavailable",
    failure_hint: ?[]const u8 = "required behavioral probe was not established",

    pub fn passed() LiveWitness {
        return .{ .status = .passed, .failure_code = null, .failure_hint = null };
    }

    pub fn failed(code: []const u8, hint: []const u8) LiveWitness {
        return .{ .status = .failed, .failure_code = code, .failure_hint = hint };
    }
};

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
    thread_pinning: LiveWitness = .{},
    paginated_fork: LiveWitness = .{},
    ephemeral_fork: LiveWitness = .{},
    external_import_history: LiveWitness = .{},
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

        const live_witness: ?LiveWitness = if (std.mem.eql(u8, descriptor.id, "thread-pinning-round-trip"))
            witnesses.thread_pinning
        else if (std.mem.eql(u8, descriptor.id, "paginated-fork"))
            witnesses.paginated_fork
        else if (std.mem.eql(u8, descriptor.id, "ephemeral-fork"))
            witnesses.ephemeral_fork
        else if (std.mem.eql(u8, descriptor.id, "external-import-history"))
            witnesses.external_import_history
        else
            null;
        const status: ProbeStatus = if (live_witness) |witness|
            witness.status
        else if (std.mem.eql(u8, descriptor.id, "initialize-lifecycle"))
            if (witnesses.lifecycle_passed) .passed else .failed
        else if (descriptor.transport != null or descriptor.code_mode_host)
            if (witnesses.lifecycle_passed) .passed else .failed
        else if (std.mem.eql(u8, descriptor.id, "server-request-coverage"))
            if (witnesses.handler_coverage_passed) .passed else .failed
        else if (std.mem.eql(u8, descriptor.id, "bounded-overload-retry"))
            if (witnesses.retry_passed) .passed else .failed
        else
            .unavailable;

        const failure_code: ?[]const u8 = if (live_witness) |witness|
            witness.failure_code
        else switch (status) {
            .passed, .not_applicable => null,
            .unavailable => "probe_unavailable",
            .failed => if (std.mem.eql(u8, descriptor.id, "initialize-lifecycle") or descriptor.transport != null or descriptor.code_mode_host)
                witnesses.lifecycle_failure_code orelse "initialize_lifecycle_failed"
            else if (std.mem.eql(u8, descriptor.id, "server-request-coverage"))
                "server_request_coverage_failed"
            else
                "bounded_overload_retry_failed",
        };
        const failure_hint: ?[]const u8 = if (live_witness) |witness|
            witness.failure_hint
        else switch (status) {
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

pub fn threadPinningProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cwd: []const u8,
    thread_id: []const u8,
) LiveWitness {
    defer deleteThread(allocator, client, thread_id);

    const pin_params = stringifyAnyAlloc(allocator, .{ .threadId = thread_id, .isPinned = true }) catch
        return LiveWitness.failed("thread_pinning_request_encode_failed", "pin parameters could not be encoded");
    defer allocator.free(pin_params);
    const pin_json = client.requestJson("thread/metadata/update", pin_params) catch
        return LiveWitness.failed("thread_pin_failed", "thread/metadata/update rejected isPinned=true");
    defer allocator.free(pin_json);
    if (!responseThreadBool(pin_json, "isPinned", true))
        return LiveWitness.failed("thread_pin_response_failed", "pin response did not witness isPinned=true");

    const pinned_list = listThreadPinState(allocator, client, cwd, true, thread_id) catch
        return LiveWitness.failed("thread_pin_list_failed", "thread/list isPinned=true filter could not be established");
    if (pinned_list == null or !pinned_list.?)
        return LiveWitness.failed("thread_pin_list_missing", "pinned thread was absent from the isPinned=true filter");
    const pinned_opposite = listThreadPinState(allocator, client, cwd, false, thread_id) catch
        return LiveWitness.failed("thread_pin_opposite_list_failed", "thread/list isPinned=false exclusion could not be established");
    if (pinned_opposite != null)
        return LiveWitness.failed("thread_pin_filter_ignored", "pinned thread remained visible through the isPinned=false filter");

    const unpin_params = stringifyAnyAlloc(allocator, .{ .threadId = thread_id, .isPinned = false }) catch
        return LiveWitness.failed("thread_pinning_request_encode_failed", "unpin parameters could not be encoded");
    defer allocator.free(unpin_params);
    const unpin_json = client.requestJson("thread/metadata/update", unpin_params) catch
        return LiveWitness.failed("thread_unpin_failed", "thread/metadata/update rejected isPinned=false");
    defer allocator.free(unpin_json);
    if (!responseThreadBool(unpin_json, "isPinned", false))
        return LiveWitness.failed("thread_unpin_response_failed", "unpin response did not witness isPinned=false");
    const unpinned_list = listThreadPinState(allocator, client, cwd, false, thread_id) catch
        return LiveWitness.failed("thread_unpin_list_failed", "thread/list isPinned=false filter could not be established");
    if (unpinned_list == null or unpinned_list.?)
        return LiveWitness.failed("thread_unpin_list_missing", "unpinned thread was absent from the isPinned=false filter");
    const unpinned_opposite = listThreadPinState(allocator, client, cwd, true, thread_id) catch
        return LiveWitness.failed("thread_unpin_opposite_list_failed", "thread/list isPinned=true exclusion could not be established");
    if (unpinned_opposite != null)
        return LiveWitness.failed("thread_unpin_filter_ignored", "unpinned thread remained visible through the isPinned=true filter");
    return LiveWitness.passed();
}

pub fn externalImportHistoryProbe(allocator: std.mem.Allocator, client: *proxy.Client, cwd: []const u8) LiveWitness {
    const detect_params = stringifyAnyAlloc(allocator, .{ .cwds = &[_][]const u8{cwd}, .includeHome = false, .maxSessionAgeDays = @as(u32, 0), .maxSessions = @as(u32, 0) }) catch
        return LiveWitness.failed("external_import_detect_encode_failed", "externalAgentConfig/detect parameters could not be encoded");
    defer allocator.free(detect_params);
    const detect_json = client.requestJson("externalAgentConfig/detect", detect_params) catch
        return LiveWitness.failed("external_import_detect_failed", "externalAgentConfig/detect failed in isolated CODEX_HOME");
    defer allocator.free(detect_json);
    if (!responseHasArray(detect_json, "items"))
        return LiveWitness.failed("external_import_detect_shape_failed", "externalAgentConfig/detect did not return items");

    const import_json = client.requestJson("externalAgentConfig/import", "{\"migrationItems\":[],\"migrationSource\":\"claude\",\"providerId\":\"cas-app-server-preflight\",\"source\":\"cas\"}") catch
        return LiveWitness.failed("external_import_failed", "externalAgentConfig/import rejected a bounded empty import");
    defer allocator.free(import_json);
    if (!responseHasString(import_json, "importId"))
        return LiveWitness.failed("external_import_shape_failed", "externalAgentConfig/import did not return importId");

    const history_json = client.requestJson("externalAgentConfig/import/recordHistory", "{\"providerId\":\"cas-app-server-preflight\",\"itemTypeResults\":[{\"itemType\":\"SESSIONS\",\"successes\":[{\"itemType\":\"SESSIONS\",\"cwd\":\"/cas/preflight\",\"source\":\"cas-preflight-session\",\"target\":\"cas-preflight-thread\"}],\"failures\":[]}]}") catch
        return LiveWitness.failed("external_import_history_failed", "externalAgentConfig/import/recordHistory rejected a bounded result group");
    defer allocator.free(history_json);
    const import_id = stringFieldAlloc(allocator, history_json, "importId") catch
        return LiveWitness.failed("external_import_history_shape_failed", "externalAgentConfig/import/recordHistory did not return importId");
    defer allocator.free(import_id);
    const read_json = client.requestJson("externalAgentConfig/import/readHistories", "{}") catch
        return LiveWitness.failed("external_import_history_read_failed", "externalAgentConfig/import/readHistories failed in isolated CODEX_HOME");
    defer allocator.free(read_json);
    if (!historyReadbackMatches(read_json, import_id))
        return LiveWitness.failed("external_import_history_readback_mismatch", "recorded provider attribution and grouped result were not preserved");
    return LiveWitness.passed();
}

fn stringifyAnyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn threadIdAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    const thread_value = root.get("thread") orelse return error.InvalidResponse;
    const thread = switch (thread_value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    const id_value = thread.get("id") orelse return error.InvalidResponse;
    const id = switch (id_value) {
        .string => |value| value,
        else => return error.InvalidResponse,
    };
    return allocator.dupe(u8, id);
}

fn responseThreadBool(raw: []const u8, field: []const u8, expected: bool) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const thread_value = root.get("thread") orelse return false;
    const thread = switch (thread_value) {
        .object => |value| value,
        else => return false,
    };
    const field_value = thread.get(field) orelse return false;
    return switch (field_value) {
        .bool => |value| value == expected,
        else => false,
    };
}

fn responseHasArray(raw: []const u8, field: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const value = root.get(field) orelse return false;
    return value == .array;
}

fn responseHasString(raw: []const u8, field: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const value = root.get(field) orelse return false;
    return value == .string;
}

fn stringFieldAlloc(allocator: std.mem.Allocator, raw: []const u8, field: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    const field_value = root.get(field) orelse return error.InvalidResponse;
    const value = switch (field_value) {
        .string => |item| item,
        else => return error.InvalidResponse,
    };
    return allocator.dupe(u8, value);
}

fn historyReadbackMatches(raw: []const u8, import_id: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const data_value = root.get("data") orelse return false;
    const data = switch (data_value) {
        .array => |value| value,
        else => return false,
    };
    for (data.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => continue,
        };
        if (!objectStringEquals(object, "importId", import_id)) continue;
        if (!objectStringEquals(object, "providerId", "cas-app-server-preflight")) return false;
        const completed_value = object.get("completedAtMs") orelse return false;
        const completed_at = switch (completed_value) {
            .integer => |value| value,
            else => return false,
        };
        if (completed_at <= 0) return false;
        const failures_value = object.get("failures") orelse return false;
        const failures = switch (failures_value) {
            .array => |value| value,
            else => return false,
        };
        if (failures.items.len != 0) return false;
        const successes_value = object.get("successes") orelse return false;
        const successes = switch (successes_value) {
            .array => |value| value,
            else => return false,
        };
        if (successes.items.len != 1) return false;
        const success = switch (successes.items[0]) {
            .object => |value| value,
            else => return false,
        };
        return objectStringEquals(success, "itemType", "SESSIONS") and
            objectStringEquals(success, "cwd", "/cas/preflight") and
            objectStringEquals(success, "source", "cas-preflight-session") and
            objectStringEquals(success, "target", "cas-preflight-thread");
    }
    return false;
}

fn objectStringEquals(object: std.json.ObjectMap, field: []const u8, expected: []const u8) bool {
    const field_value = object.get(field) orelse return false;
    const value = switch (field_value) {
        .string => |item| item,
        else => return false,
    };
    return std.mem.eql(u8, value, expected);
}

fn listThreadPinState(allocator: std.mem.Allocator, client: *proxy.Client, cwd: []const u8, is_pinned: bool, thread_id: []const u8) !?bool {
    const params = try threadListParamsAlloc(allocator, cwd, is_pinned);
    defer allocator.free(params);
    const raw = try client.requestJson("thread/list", params);
    defer allocator.free(raw);
    return threadPinStateFromList(allocator, raw, thread_id);
}

fn threadPinStateFromList(allocator: std.mem.Allocator, raw: []const u8, thread_id: []const u8) !?bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    const data_value = root.get("data") orelse return error.InvalidResponse;
    const data = switch (data_value) {
        .array => |value| value,
        else => return error.InvalidResponse,
    };
    for (data.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => continue,
        };
        const id_value = object.get("id") orelse continue;
        const id = switch (id_value) {
            .string => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, id, thread_id)) continue;
        const pinned_value = object.get("isPinned") orelse return error.InvalidResponse;
        return switch (pinned_value) {
            .bool => |value| value,
            else => error.InvalidResponse,
        };
    }
    return null;
}

fn threadListParamsAlloc(allocator: std.mem.Allocator, cwd: []const u8, is_pinned: bool) ![]u8 {
    return stringifyAnyAlloc(allocator, .{
        .cwd = cwd,
        .isPinned = is_pinned,
        .limit = @as(u32, 100),
        .sourceKinds = &[_][]const u8{"cli"},
        .useStateDbOnly = false,
    });
}

fn deleteThread(allocator: std.mem.Allocator, client: *proxy.Client, thread_id: []const u8) void {
    const params = stringifyAnyAlloc(allocator, .{ .threadId = thread_id }) catch return;
    defer allocator.free(params);
    const response = client.requestJson("thread/delete", params) catch return;
    allocator.free(response);
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

test "live witnesses replace only their exact fail-closed rows" {
    const report = buildReport(.full, .{ .transport = .stdio }, .{
        .lifecycle_passed = true,
        .handler_coverage_passed = true,
        .retry_passed = true,
        .thread_pinning = LiveWitness.passed(),
        .external_import_history = LiveWitness.passed(),
    });
    try std.testing.expectEqualStrings("passed", report.rows[7].status);
    try std.testing.expectEqualStrings("thread-pinning-round-trip", report.rows[7].id);
    try std.testing.expectEqualStrings("unavailable", report.rows[8].status);
    try std.testing.expectEqualStrings("paginated-fork", report.rows[8].id);
    try std.testing.expectEqualStrings("unavailable", report.rows[9].status);
    try std.testing.expectEqualStrings("ephemeral-fork", report.rows[9].id);
    try std.testing.expectEqualStrings("passed", report.rows[11].status);
    try std.testing.expectEqualStrings("external-import-history", report.rows[11].id);
    try std.testing.expect(!report.compatible);
}

test "probe response helpers require exact fields and types" {
    const allocator = std.testing.allocator;
    const id = try threadIdAlloc(allocator, "{\"thread\":{\"id\":\"thread-1\",\"isPinned\":true}}");
    defer allocator.free(id);
    try std.testing.expectEqualStrings("thread-1", id);
    try std.testing.expect(responseThreadBool("{\"thread\":{\"isPinned\":true}}", "isPinned", true));
    try std.testing.expect(!responseThreadBool("{\"thread\":{\"isPinned\":\"true\"}}", "isPinned", true));
    try std.testing.expect(responseHasArray("{\"items\":[]}", "items"));
    try std.testing.expect(!responseHasArray("{\"items\":{}}", "items"));
    try std.testing.expect(responseHasString("{\"importId\":\"import-1\"}", "importId"));
    try std.testing.expect(!responseHasString("{\"importId\":1}", "importId"));

    const import_id = try stringFieldAlloc(allocator, "{\"importId\":\"import-1\"}", "importId");
    defer allocator.free(import_id);
    try std.testing.expectEqualStrings("import-1", import_id);
}

test "pin list parsing distinguishes absence from the opposite state" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(
        @as(?bool, true),
        try threadPinStateFromList(allocator, "{\"data\":[{\"id\":\"thread-1\",\"isPinned\":true}]}", "thread-1"),
    );
    try std.testing.expectEqual(
        @as(?bool, false),
        try threadPinStateFromList(allocator, "{\"data\":[{\"id\":\"thread-1\",\"isPinned\":false}]}", "thread-1"),
    );
    try std.testing.expectEqual(
        @as(?bool, null),
        try threadPinStateFromList(allocator, "{\"data\":[{\"id\":\"thread-2\",\"isPinned\":true}]}", "thread-1"),
    );
}

test "import history readback requires provider and exact grouped success" {
    const valid =
        "{\"data\":[{\"importId\":\"import-1\",\"providerId\":\"cas-app-server-preflight\",\"completedAtMs\":1,\"successes\":[{\"itemType\":\"SESSIONS\",\"cwd\":\"/cas/preflight\",\"source\":\"cas-preflight-session\",\"target\":\"cas-preflight-thread\"}],\"failures\":[]}],\"connectors\":[]}";
    try std.testing.expect(historyReadbackMatches(valid, "import-1"));
    try std.testing.expect(!historyReadbackMatches(
        "{\"data\":[{\"importId\":\"import-1\",\"providerId\":null,\"completedAtMs\":1,\"successes\":[],\"failures\":[]}],\"connectors\":[]}",
        "import-1",
    ));
}

test "pin list filter selects the isolated CLI fixture within a bounded page" {
    const allocator = std.testing.allocator;
    const raw = try threadListParamsAlloc(allocator, "/tmp/probe", true);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("/tmp/probe", root.get("cwd").?.string);
    try std.testing.expect(root.get("isPinned").?.bool);
    try std.testing.expectEqual(@as(i64, 100), root.get("limit").?.integer);
    try std.testing.expect(!root.get("useStateDbOnly").?.bool);
    const source_kinds = root.get("sourceKinds").?.array;
    try std.testing.expectEqual(@as(usize, 1), source_kinds.items.len);
    try std.testing.expectEqualStrings("cli", source_kinds.items[0].string);
}
