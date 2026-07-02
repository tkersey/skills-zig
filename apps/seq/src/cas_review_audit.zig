const std = @import("std");
const query = @import("query/engine.zig");
const spec = @import("types/spec.zig");
const time_utils = @import("time_utils.zig");

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const projection_fields = [_][]const u8{
    "session_id",
    "source_path",
    "receipt_path",
    "record_id",
    "canonical_source",
    "canonical_status",
    "parent_visible_status",
    "cwd",
    "command_surface",
    "surface",
    "backend_class",
    "principal_kind",
    "principal_proof_usable",
    "principal_reduced",
    "principal_fallback_used",
    "review_attempt_phase",
    "review_attempt_exists",
    "tuple_verdict_exists",
    "failure_code",
    "failure_class",
    "retryable_same_tuple_now",
    "lane_id",
    "managed_server_pid",
    "managed_server_listen_url",
    "server_exit_status",
    "stderr_log_path",
    "review_count",
    "last_review_thread_id",
    "review_thread_id",
    "review_turn_id",
    "base_sha",
    "head_sha",
    "target_fingerprint",
    "review_verdict_status",
    "finding_count",
    "account_resource_signal",
    "transport_signal",
    "record_path",
    "event_log_path",
    "review_broker_action",
    "review_broker_reason",
};

pub const summary_fields = [_][]const u8{
    "row_count",
    "pre_review_lane_transport_lost_count",
    "review_attempt_transport_failure_count",
    "completed_findings_count",
    "completed_clean_count",
    "account_resource_exhausted_count",
    "timeout_with_handle_count",
    "duplicate_prevented_count",
    "start_wait_normalized_count",
    "start_wait_unormalized_count",
    "broker_run_count",
    "broker_auto_replaced_dead_transport_count",
    "broker_attached_existing_count",
    "broker_blocked_live_count",
    "manual_recovery_command_count",
    "lane_backend_status",
};

pub const Mode = enum {
    summary,
    rows,
    report,

    pub fn parse(text: ?[]const u8) !Mode {
        const value = text orelse return .summary;
        if (std.mem.eql(u8, value, "summary")) return .summary;
        if (std.mem.eql(u8, value, "rows")) return .rows;
        if (std.mem.eql(u8, value, "report")) return .report;
        return error.InvalidModeArg;
    }
};

pub const Params = struct {
    root: []const u8,
    path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
    exclude_current_session_id: ?[]const u8 = null,
    receipt_paths: []const []const u8 = &.{},
    receipt_globs: []const []const u8 = &.{},
    base_sha: ?[]const u8 = null,
    head_sha: ?[]const u8 = null,
    target_fingerprint: ?[]const u8 = null,
};

pub const Audit = struct {
    rows: std.ArrayList(query.Row) = .empty,
    summary: Summary = .{},

    pub fn deinit(self: *Audit, allocator: std.mem.Allocator) void {
        for (self.rows.items) |*row| row.deinit();
        self.rows.deinit(allocator);
    }
};

pub const Summary = struct {
    row_count: i64 = 0,
    pre_review_lane_transport_lost_count: i64 = 0,
    review_attempt_transport_failure_count: i64 = 0,
    completed_findings_count: i64 = 0,
    completed_clean_count: i64 = 0,
    account_resource_exhausted_count: i64 = 0,
    timeout_with_handle_count: i64 = 0,
    duplicate_prevented_count: i64 = 0,
    start_wait_normalized_count: i64 = 0,
    start_wait_unormalized_count: i64 = 0,
    broker_run_count: i64 = 0,
    broker_auto_replaced_dead_transport_count: i64 = 0,
    broker_attached_existing_count: i64 = 0,
    broker_blocked_live_count: i64 = 0,
    manual_recovery_command_count: i64 = 0,
    lane_backend_status: []const u8 = "unavailable",
};

const PendingCall = struct {
    call_id: []const u8,
    session_id: []const u8,
    timestamp: []const u8,
    command: []const u8,
    cwd: ?[]const u8,
};

pub fn compile(allocator: std.mem.Allocator, params: Params) !Audit {
    var audit = Audit{};
    errdefer audit.deinit(allocator);

    var dedupe = std.StringHashMap(void).init(allocator);
    defer {
        var it = dedupe.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        dedupe.deinit();
    }

    if (params.path) |path| {
        try scanSessionPath(allocator, path, params, &audit, &dedupe);
    } else if (hasSessionScanScope(params)) {
        try scanSessionRoot(allocator, params.root, params, &audit, &dedupe);
    }

    for (params.receipt_paths) |path| {
        try scanReceiptPath(allocator, path, params, &audit, &dedupe);
    }
    for (params.receipt_globs) |glob| {
        try scanReceiptGlob(allocator, glob, params, &audit, &dedupe);
    }

    audit.summary = summarize(audit.rows.items);
    return audit;
}

fn hasSessionScanScope(params: Params) bool {
    return params.session_id != null or
        params.repo != null or
        params.workdir != null or
        params.since != null or
        params.until != null or
        params.since_ms != null or
        params.until_ms != null;
}

pub fn summaryRow(allocator: std.mem.Allocator, summary: Summary) !query.Row {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try row.putStaticKey("row_count", .{ .int = summary.row_count });
    try row.putStaticKey("pre_review_lane_transport_lost_count", .{ .int = summary.pre_review_lane_transport_lost_count });
    try row.putStaticKey("review_attempt_transport_failure_count", .{ .int = summary.review_attempt_transport_failure_count });
    try row.putStaticKey("completed_findings_count", .{ .int = summary.completed_findings_count });
    try row.putStaticKey("completed_clean_count", .{ .int = summary.completed_clean_count });
    try row.putStaticKey("account_resource_exhausted_count", .{ .int = summary.account_resource_exhausted_count });
    try row.putStaticKey("timeout_with_handle_count", .{ .int = summary.timeout_with_handle_count });
    try row.putStaticKey("duplicate_prevented_count", .{ .int = summary.duplicate_prevented_count });
    try row.putStaticKey("start_wait_normalized_count", .{ .int = summary.start_wait_normalized_count });
    try row.putStaticKey("start_wait_unormalized_count", .{ .int = summary.start_wait_unormalized_count });
    try row.putStaticKey("broker_run_count", .{ .int = summary.broker_run_count });
    try row.putStaticKey("broker_auto_replaced_dead_transport_count", .{ .int = summary.broker_auto_replaced_dead_transport_count });
    try row.putStaticKey("broker_attached_existing_count", .{ .int = summary.broker_attached_existing_count });
    try row.putStaticKey("broker_blocked_live_count", .{ .int = summary.broker_blocked_live_count });
    try row.putStaticKey("manual_recovery_command_count", .{ .int = summary.manual_recovery_command_count });
    try row.putStaticKey("lane_backend_status", .{ .string = summary.lane_backend_status });
    return row;
}

pub fn writeReport(writer: anytype, summary: Summary) !void {
    try writer.writeAll("# seq cas-review-audit\n\n");
    try writer.print("- row_count: {d}\n", .{summary.row_count});
    try writer.print("- lane_backend_status: {s}\n", .{summary.lane_backend_status});
    try writer.print("- pre_review_lane_transport_lost_count: {d}\n", .{summary.pre_review_lane_transport_lost_count});
    try writer.print("- review_attempt_transport_failure_count: {d}\n", .{summary.review_attempt_transport_failure_count});
    try writer.print("- completed_findings_count: {d}\n", .{summary.completed_findings_count});
    try writer.print("- completed_clean_count: {d}\n", .{summary.completed_clean_count});
    try writer.print("- account_resource_exhausted_count: {d}\n", .{summary.account_resource_exhausted_count});
    try writer.print("- timeout_with_handle_count: {d}\n", .{summary.timeout_with_handle_count});
    try writer.print("- duplicate_prevented_count: {d}\n", .{summary.duplicate_prevented_count});
    try writer.print("- start_wait_normalized_count: {d}\n", .{summary.start_wait_normalized_count});
    try writer.print("- start_wait_unormalized_count: {d}\n", .{summary.start_wait_unormalized_count});
    try writer.print("- broker_run_count: {d}\n", .{summary.broker_run_count});
    try writer.print("- broker_auto_replaced_dead_transport_count: {d}\n", .{summary.broker_auto_replaced_dead_transport_count});
    try writer.print("- broker_attached_existing_count: {d}\n", .{summary.broker_attached_existing_count});
    try writer.print("- broker_blocked_live_count: {d}\n", .{summary.broker_blocked_live_count});
    try writer.print("- manual_recovery_command_count: {d}\n", .{summary.manual_recovery_command_count});
    try writer.writeAll("\nCompleted findings are review outcomes, not CAS backend failures.\n");
}

fn scanSessionRoot(
    allocator: std.mem.Allocator,
    root: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    var root_dir = std.Io.Dir.openDirAbsolute(defaultIo(), root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer root_dir.close(defaultIo());

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;
        const abs_path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(abs_path);
        try scanSessionPath(allocator, abs_path, params, audit, dedupe);
    }
}

fn scanSessionPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, allocator, .limited(64 * 1024 * 1024)) catch return;
    defer allocator.free(text);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var pending = std.StringHashMap(PendingCall).init(aa);
    var session_id: []const u8 = "";

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, aa, line, .{}) catch continue;
        const root = object(parsed.value) orelse continue;
        if (stringField(root, "timestamp")) |timestamp| {
            if (!withinWindow(timestamp, params)) continue;
        }

        if (optEql(stringField(root, "type"), "session_meta")) {
            if (objectField(root, "payload")) |meta| {
                if (stringField(meta, "id")) |id| session_id = id;
            }
            continue;
        }

        const payload = objectField(root, "payload") orelse continue;
        const payload_type = stringField(payload, "type") orelse continue;

        if (std.mem.eql(u8, payload_type, "session_meta")) {
            if (objectField(payload, "payload")) |meta| {
                if (stringField(meta, "id")) |id| session_id = id;
            }
            continue;
        }

        if (std.mem.eql(u8, payload_type, "function_call")) {
            const tool_name = stringField(payload, "name") orelse continue;
            if (!std.mem.eql(u8, tool_name, "exec_command")) continue;
            const call_id = stringField(payload, "call_id") orelse continue;
            const arguments = stringField(payload, "arguments") orelse continue;
            const args_parsed = std.json.parseFromSlice(std.json.Value, aa, arguments, .{}) catch continue;
            const args_obj = object(args_parsed.value) orelse continue;
            const cmd = stringField(args_obj, "cmd") orelse continue;
            if (!looksLikeCasReviewCommand(cmd)) continue;
            const ts = stringField(root, "timestamp") orelse "";
            const call = PendingCall{
                .call_id = call_id,
                .session_id = session_id,
                .timestamp = ts,
                .command = cmd,
                .cwd = nullableString(args_obj, "workdir") orelse nullableString(args_obj, "cwd"),
            };
            try pending.put(call_id, call);
            continue;
        }

        if (std.mem.eql(u8, payload_type, "exec_command_end") or std.mem.eql(u8, payload_type, "function_call_output")) {
            const call_id = stringField(payload, "call_id") orelse continue;
            var call = pending.get(call_id) orelse continue;
            if (call.cwd == null) call.cwd = nullableString(payload, "cwd");
            try pending.put(call_id, call);
            if (manualRecoveryCommand(call.command)) {
                try appendManualRecoveryCommandRow(allocator, call, path, params, audit, dedupe);
            }
            const stdout = nullableStringAny(payload, &.{ "stdout", "output", "aggregated_output" }) orelse "";
            const stderr = stringField(payload, "stderr") orelse "";
            try appendRowsFromCommandText(allocator, stdout, stderr, call, path, params, audit, dedupe);
        }
    }

    var leftovers = pending.valueIterator();
    while (leftovers.next()) |call| {
        if (manualRecoveryCommand(call.command)) {
            try appendManualRecoveryCommandRow(allocator, call.*, path, params, audit, dedupe);
        }
    }
}

fn appendManualRecoveryCommandRow(
    allocator: std.mem.Allocator,
    call: PendingCall,
    session_path: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putStringOrNull(&row, "session_id", nonEmpty(call.session_id));
    try row.putStaticKey("source_path", .{ .string = session_path });
    try putStringOrNull(&row, "receipt_path", null);
    try putStringOrNull(&row, "cwd", call.cwd);
    try row.putStaticKey("command_surface", .{ .string = call.command });
    try row.putStaticKey("surface", .{ .string = "manual_recovery_command" });
    try putStringOrNull(&row, "backend_class", null);
    try putStringOrNull(&row, "review_attempt_phase", null);
    try row.putStaticKey("review_attempt_exists", .{ .bool = false });
    try row.putStaticKey("tuple_verdict_exists", .{ .bool = false });
    try putStringOrNull(&row, "failure_code", null);
    try putStringOrNull(&row, "failure_class", null);
    try putBoolOrNull(&row, "retryable_same_tuple_now", null);
    try putStringOrNull(&row, "lane_id", null);
    try putIntOrNull(&row, "managed_server_pid", null);
    try putStringOrNull(&row, "managed_server_listen_url", null);
    try putStringOrNull(&row, "server_exit_status", null);
    try putStringOrNull(&row, "stderr_log_path", null);
    try row.putStaticKey("review_count", .{ .int = 0 });
    try putStringOrNull(&row, "last_review_thread_id", null);
    try putStringOrNull(&row, "review_thread_id", null);
    try putStringOrNull(&row, "review_turn_id", null);
    try putStringOrNull(&row, "base_sha", null);
    try putStringOrNull(&row, "head_sha", null);
    try putStringOrNull(&row, "target_fingerprint", null);
    try putStringOrNull(&row, "review_verdict_status", null);
    try row.putStaticKey("finding_count", .{ .int = 0 });
    try row.putStaticKey("account_resource_signal", .{ .bool = false });
    try row.putStaticKey("transport_signal", .{ .bool = false });
    try putStringOrNull(&row, "record_path", null);
    try putStringOrNull(&row, "event_log_path", null);
    try putStringOrNull(&row, "review_broker_action", null);
    try putStringOrNull(&row, "review_broker_reason", null);

    const fallback = try std.fmt.allocPrint(allocator, "{s}:manual-recovery", .{call.call_id});
    defer allocator.free(fallback);
    try appendRowIfMatched(allocator, row, session_path, fallback, params, audit, dedupe);
}

fn scanReceiptPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, allocator, .limited(64 * 1024 * 1024)) catch return;
    defer allocator.free(text);
    try appendRowsFromReceiptText(allocator, text, path, params, audit, dedupe);
}

fn scanReceiptGlob(
    allocator: std.mem.Allocator,
    glob: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    if (std.mem.indexOfScalar(u8, glob, '*') == null) {
        try scanReceiptPath(allocator, glob, params, audit, dedupe);
        return;
    }
    const slash = std.mem.lastIndexOfScalar(u8, glob, '/');
    const dir_path = if (slash) |idx| if (idx == 0) "/" else glob[0..idx] else params.root;
    const pattern = if (slash) |idx| glob[idx + 1 ..] else glob;
    var dir = std.Io.Dir.cwd().openDir(defaultIo(), dir_path, .{ .iterate = true }) catch return;
    defer dir.close(defaultIo());
    var iter = dir.iterate();
    while (try iter.next(defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!globMatch(pattern, entry.name)) continue;
        const abs_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(abs_path);
        try scanReceiptPath(allocator, abs_path, params, audit, dedupe);
    }
}

fn appendRowsFromCommandText(
    allocator: std.mem.Allocator,
    stdout: []const u8,
    stderr: []const u8,
    call: PendingCall,
    session_path: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    _ = stderr;
    var cursor: usize = 0;
    while (findJsonObject(stdout, &cursor)) |json_text| {
        try appendRowsFromJsonText(allocator, json_text, .{
            .session_id = call.session_id,
            .cwd = call.cwd,
            .command_surface = call.command,
            .source_path = session_path,
            .default_backend_class = backendFromCommand(call.command),
        }, session_path, call.call_id, params, audit, dedupe);
    }
}

fn appendRowsFromReceiptText(
    allocator: std.mem.Allocator,
    text: []const u8,
    path: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    var cursor: usize = 0;
    var found = false;
    var receipt_index: usize = 0;
    while (findJsonObject(text, &cursor)) |json_text| {
        found = true;
        receipt_index += 1;
        var fallback_buf: [64]u8 = undefined;
        const fallback = std.fmt.bufPrint(fallback_buf[0..], "receipt:{d}", .{receipt_index}) catch "receipt";
        try appendRowsFromJsonText(allocator, json_text, .{
            .session_id = "",
            .cwd = null,
            .command_surface = "receipt",
            .source_path = path,
            .default_backend_class = "cas-receipt-normalized",
        }, path, fallback, params, audit, dedupe);
    }
    if (!found) return;
}

const ClassifyContext = struct {
    session_id: []const u8,
    cwd: ?[]const u8,
    command_surface: []const u8,
    source_path: []const u8,
    default_backend_class: []const u8,
};

fn appendRowsFromJsonText(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    ctx: ClassifyContext,
    dedupe_path: []const u8,
    dedupe_id: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch {
        const row = classifyReceiptText(allocator, json_text, ctx) catch return;
        try appendRowIfMatched(allocator, row, dedupe_path, dedupe_id, params, audit, dedupe);
        return;
    };
    defer parsed.deinit();
    const root = object(parsed.value) orelse return;
    if (isCasReviewEvidenceRecord(root)) {
        const row = classifyCasRerObject(allocator, root, ctx) catch return;
        try appendRowIfMatched(allocator, row, dedupe_path, dedupe_id, params, audit, dedupe);
        return;
    }
    if (isCasRunEnvelope(root)) {
        try appendRowsFromCasRunEnvelope(allocator, root, ctx, dedupe_path, dedupe_id, params, audit, dedupe);
        return;
    }
    if (isCasImportEnvelope(root)) {
        try appendRowsFromCasImportEnvelope(allocator, root, ctx, dedupe_path, dedupe_id, params, audit, dedupe);
        return;
    }
    if (isCasImportRecordWrapper(root)) {
        try appendRowFromCasImportRecordWrapper(allocator, root, ctx, dedupe_path, dedupe_id, params, audit, dedupe);
        return;
    }
    if (isSmokeArtifactObject(root)) {
        try appendSmokeArtifactRows(allocator, root, ctx, dedupe_path, dedupe_id, params, audit, dedupe);
        return;
    }
    if (!looksLikeReceiptObject(root)) return;
    const row = classifyReceiptObject(allocator, root, ctx) catch return;
    try appendRowIfMatched(allocator, row, dedupe_path, dedupe_id, params, audit, dedupe);
}

fn appendRowIfMatched(
    allocator: std.mem.Allocator,
    row: query.Row,
    dedupe_path: []const u8,
    dedupe_id: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    var owned_row = row;
    errdefer owned_row.deinit();
    if (!rowMatchesFilters(owned_row, params)) {
        owned_row.deinit();
        return;
    }
    if (try claimDedupeKey(allocator, owned_row, dedupe_path, dedupe_id, dedupe)) {
        try audit.rows.append(allocator, owned_row);
    } else {
        owned_row.deinit();
    }
}

fn isSmokeArtifactObject(root: std.json.ObjectMap) bool {
    return optEql(nullableString(root, "suiteVersion"), "CAS-RSS-v1") or
        optEql(nullableString(root, "promotionVersion"), "CAS-RSP-v1");
}

fn isCasReviewEvidenceRecord(root: std.json.ObjectMap) bool {
    return optEql(nullableString(root, "schema"), "CAS-RER-v1");
}

fn isCasImportEnvelope(root: std.json.ObjectMap) bool {
    return optEql(nullableString(root, "schema"), "CAS-IMPORT-v1");
}

fn isCasImportRecordWrapper(root: std.json.ObjectMap) bool {
    const validation = objectField(root, "validation") orelse return false;
    if (boolField(validation, "ok") != true) return false;
    const record = objectField(root, "record") orelse return false;
    return isCasReviewEvidenceRecord(record);
}

fn isCasRunEnvelope(root: std.json.ObjectMap) bool {
    return optEql(nullableString(root, "schema"), "CAS-RUN-v1");
}

fn appendRowsFromCasRunEnvelope(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    ctx: ClassifyContext,
    dedupe_path: []const u8,
    dedupe_id: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    const record = objectField(root, "record") orelse return;
    if (!isCasReviewEvidenceRecord(record)) return;
    const row = try classifyCasRerObject(allocator, record, ctx);
    const record_id = nullableString(record, "recordId") orelse "cas-run-rer";
    const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ dedupe_path, dedupe_id, record_id });
    defer allocator.free(key);
    try appendRowIfMatched(allocator, row, key, key, params, audit, dedupe);
}

fn appendRowsFromCasImportEnvelope(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    ctx: ClassifyContext,
    dedupe_path: []const u8,
    dedupe_id: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    const records_value = root.get("records") orelse return;
    const records = switch (records_value) {
        .array => |array| array.items,
        else => return,
    };
    for (records, 0..) |record_value, idx| {
        const item = object(record_value) orelse continue;
        const validation = objectField(item, "validation") orelse continue;
        if (boolField(validation, "ok") != true) continue;
        const record = objectField(item, "record") orelse continue;
        if (!isCasReviewEvidenceRecord(record)) continue;
        const row = try classifyCasRerObject(allocator, record, ctx);
        var fallback_buf: [64]u8 = undefined;
        const record_id = nullableString(record, "recordId") orelse std.fmt.bufPrint(fallback_buf[0..], "cas-rer:{d}", .{idx}) catch "cas-rer";
        const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ dedupe_path, dedupe_id, record_id });
        defer allocator.free(key);
        try appendRowIfMatched(allocator, row, key, key, params, audit, dedupe);
    }
}

fn appendRowFromCasImportRecordWrapper(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    ctx: ClassifyContext,
    dedupe_path: []const u8,
    dedupe_id: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    const record = objectField(root, "record") orelse return;
    if (!isCasReviewEvidenceRecord(record)) return;
    const row = try classifyCasRerObject(allocator, record, ctx);
    const record_id = nullableString(record, "recordId") orelse "cas-rer-wrapper";
    const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ dedupe_path, dedupe_id, record_id });
    defer allocator.free(key);
    try appendRowIfMatched(allocator, row, key, key, params, audit, dedupe);
}

fn appendSmokeArtifactRows(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    ctx: ClassifyContext,
    dedupe_path: []const u8,
    dedupe_id: []const u8,
    params: Params,
    audit: *Audit,
    dedupe: *std.StringHashMap(void),
) !void {
    const results_value = root.get("results") orelse return;
    const results = switch (results_value) {
        .array => |array| array.items,
        else => return,
    };
    for (results, 0..) |result_value, idx| {
        const result = object(result_value) orelse continue;
        const row = try classifySmokeResultObject(allocator, root, result, ctx);
        var fallback_buf: [64]u8 = undefined;
        const run_id = nullableString(result, "runId") orelse nullableString(result, "run_id") orelse std.fmt.bufPrint(fallback_buf[0..], "result:{d}", .{idx}) catch "result";
        const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ dedupe_path, dedupe_id, run_id });
        defer allocator.free(key);
        try appendRowIfMatched(allocator, row, key, key, params, audit, dedupe);
    }
}

fn classifySmokeResultObject(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    result: std.json.ObjectMap,
    ctx: ClassifyContext,
) !query.Row {
    const verdict = objectField(result, "reviewVerdict");
    const failure_code = nullableStringAny(result, &.{ "failureCode", "failure_code" });
    const review_thread_id = nullableStringAny(result, &.{ "reviewThreadId", "review_thread_id" });
    const review_attempt_exists = boolFieldAny(result, &.{ "reviewAttemptExists", "review_attempt_exists" }) orelse (review_thread_id != null);
    const tuple_verdict_exists = boolFieldAny(result, &.{ "tupleVerdictExists", "tuple_verdict_exists" }) orelse false;
    const phase = nullableStringAny(result, &.{ "reviewAttemptPhase", "review_attempt_phase" }) orelse smokeResultPhase(review_thread_id, failure_code, tuple_verdict_exists);
    const backend_class = nullableStringAny(result, &.{ "backendClass", "backend_class" }) orelse "cas-lane";
    const verdict_status_raw = nullableStringAny(result, &.{ "reviewVerdictStatus", "review_verdict_status" }) orelse if (verdict) |v| nullableString(v, "status") else null;
    const verdict_status = canonicalSmokeVerdictStatus(verdict_status_raw, failure_code, review_thread_id, tuple_verdict_exists);
    const record_path = nullableStringAny(result, &.{ "recordPath", "record_path", "receiptPath", "receipt_path" });
    const event_log_path = nullableStringAny(result, &.{ "eventLogPath", "event_log_path" });

    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putStringOrNull(&row, "session_id", nonEmpty(ctx.session_id));
    try row.putStaticKey("source_path", .{ .string = ctx.source_path });
    try putStringOrNull(&row, "receipt_path", record_path orelse if (std.mem.eql(u8, ctx.command_surface, "receipt")) ctx.source_path else null);
    try putStringOrNull(&row, "cwd", nullableStringAny(root, &.{ "cwd", "workdir" }) orelse ctx.cwd);
    try row.putStaticKey("command_surface", .{ .string = if (nullableString(root, "suiteVersion") != null) "lane-smoke-suite" else "lane-smoke-until-fixed" });
    try row.putStaticKey("surface", .{ .string = "runner" });
    try row.putStaticKey("backend_class", .{ .string = backend_class });
    try row.putStaticKey("review_attempt_phase", .{ .string = phase });
    try row.putStaticKey("review_attempt_exists", .{ .bool = review_attempt_exists });
    try row.putStaticKey("tuple_verdict_exists", .{ .bool = tuple_verdict_exists });
    try putStringOrNull(&row, "failure_code", failure_code);
    try putStringOrNull(&row, "failure_class", nullableStringAny(result, &.{ "failureClass", "failure_class" }) orelse failureClassForCode(failure_code));
    try putBoolOrNull(&row, "retryable_same_tuple_now", boolFieldAny(result, &.{ "retryableSameTupleNow", "retryable_same_tuple_now" }));
    try putStringOrNull(&row, "lane_id", nullableStringAny(result, &.{ "laneId", "lane_id" }));
    try putIntOrNull(&row, "managed_server_pid", intFieldAny(result, &.{ "managedServerPid", "managed_server_pid" }));
    try putStringOrNull(&row, "managed_server_listen_url", nullableStringAny(result, &.{ "managedServerListenUrl", "managed_server_listen_url" }));
    try putStringOrNull(&row, "server_exit_status", nullableStringAny(result, &.{ "serverExitStatus", "server_exit_status" }));
    try putStringOrNull(&row, "stderr_log_path", nullableStringAny(result, &.{ "stderrLogPath", "stderr_log_path" }));
    try row.putStaticKey("review_count", .{ .int = intFieldAny(result, &.{ "reviewCount", "review_count" }) orelse 0 });
    try putStringOrNull(&row, "last_review_thread_id", nullableStringAny(result, &.{ "lastReviewThreadId", "last_review_thread_id" }));
    try putStringOrNull(&row, "review_thread_id", review_thread_id);
    try putStringOrNull(&row, "review_turn_id", nullableStringAny(result, &.{ "reviewTurnId", "review_turn_id" }));
    try putStringOrNull(&row, "base_sha", nullableStringAny(result, &.{ "baseSha", "base_sha" }));
    try putStringOrNull(&row, "head_sha", nullableStringAny(result, &.{ "headSha", "head_sha" }));
    try putStringOrNull(&row, "target_fingerprint", nullableStringAny(result, &.{ "targetFingerprint", "target_fingerprint" }));
    try putStringOrNull(&row, "review_verdict_status", verdict_status);
    try row.putStaticKey("finding_count", .{ .int = intFieldAny(result, &.{ "findingCount", "finding_count" }) orelse 0 });
    try row.putStaticKey("account_resource_signal", .{ .bool = accountResourceSignal(result, null) });
    try row.putStaticKey("transport_signal", .{ .bool = transportSignal(failure_code, nullableStringAny(result, &.{ "failureClass", "failure_class" })) });
    try putStringOrNull(&row, "record_path", record_path);
    try putStringOrNull(&row, "event_log_path", event_log_path);
    try putStringOrNull(&row, "review_broker_action", null);
    try putStringOrNull(&row, "review_broker_reason", null);
    return row;
}

fn canonicalSmokeVerdictStatus(raw: ?[]const u8, failure_code: ?[]const u8, review_thread_id: ?[]const u8, tuple_verdict_exists: bool) ?[]const u8 {
    if (raw) |status| return canonicalVerdictStatus(status, failure_code, review_thread_id);
    if (optEql(failure_code, "wait_timed_out")) return "timeout";
    if (tuple_verdict_exists) return "incomplete";
    return null;
}

fn smokeResultPhase(review_thread_id: ?[]const u8, failure_code: ?[]const u8, tuple_verdict_exists: bool) []const u8 {
    if (tuple_verdict_exists) return "normalized_verdict";
    if (review_thread_id != null) {
        if (optEql(failure_code, "wait_timed_out")) return "review_waiting";
        return "review_started";
    }
    if (optEql(failure_code, "pre_review_lane_transport_lost")) return "pre_review_start";
    return "pre_lane_start";
}

fn classifyReceiptText(allocator: std.mem.Allocator, text: []const u8, ctx: ClassifyContext) !query.Row {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const root = object(parsed.value) orelse return error.InvalidReceipt;
    if (isCasReviewEvidenceRecord(root)) return classifyCasRerObject(allocator, root, ctx);
    if (!looksLikeReceiptObject(root)) return error.InvalidReceipt;
    return classifyReceiptObject(allocator, root, ctx);
}

fn classifyReceiptObject(allocator: std.mem.Allocator, root: std.json.ObjectMap, ctx: ClassifyContext) !query.Row {
    const verdict = objectField(root, "reviewVerdict");
    const broker = objectField(root, "reviewBrokerDecision");
    const broker_action = if (broker) |value| nullableString(value, "action") else null;
    const broker_reason = if (broker) |value| nullableString(value, "reason") else null;
    const surface = nullableString(root, "surface") orelse if (verdict != null) "normalize" else "runner";
    const failure_code_raw = nullableStringAny(root, &.{ "failureCode", "failure_code" });
    const review_thread_id = nullableStringAny(root, &.{ "reviewThreadId", "review_thread_id" }) orelse if (verdict) |v| nullableStringAny(v, &.{ "reviewThreadId", "review_thread_id" }) else null;
    const review_turn_id = nullableStringAny(root, &.{ "reviewTurnId", "review_turn_id" }) orelse if (verdict) |v| nullableStringAny(v, &.{ "reviewTurnId", "review_turn_id" }) else null;
    const base_sha = nullableStringAny(root, &.{ "baseSha", "base_sha" }) orelse if (verdict) |v| nullableStringAny(v, &.{ "baseSha", "base_sha" }) else null;
    const head_sha = nullableStringAny(root, &.{ "headSha", "head_sha" }) orelse if (verdict) |v| nullableStringAny(v, &.{ "headSha", "head_sha" }) else null;
    const target_fingerprint = nullableStringAny(root, &.{ "targetFingerprint", "target_fingerprint" }) orelse if (verdict) |v| nullableStringAny(v, &.{ "targetFingerprint", "target_fingerprint" }) else null;
    const stored_terminal = storedTerminalProjection(allocator, root, base_sha, head_sha, target_fingerprint);
    const review_count = intFieldAny(root, &.{ "reviewCount", "review_count" }) orelse 0;
    const last_review_thread_id = nullableStringAny(root, &.{ "lastReviewThreadId", "last_review_thread_id" });
    const last_head_sha = nullableStringAny(root, &.{ "lastHeadSha", "last_head_sha" });
    const verdict_status_raw = if (verdict) |v| nullableString(v, "status") else reviewVerdictStatusRoot(root) orelse stored_terminal.status;

    const legacy_pre_review_transport =
        optEql(failure_code_raw, "lane_transport_lost") and
        review_count == 0 and
        last_review_thread_id == null and
        last_head_sha == null and
        review_thread_id == null and
        verdict == null;

    const failure_code = if (legacy_pre_review_transport) "pre_review_lane_transport_lost" else failure_code_raw;
    const verdict_status = canonicalVerdictStatus(verdict_status_raw, failure_code, review_thread_id);
    const phase = nullableStringAny(root, &.{ "reviewAttemptPhase", "review_attempt_phase" }) orelse if (stored_terminal.tuple_bound) "normalized_verdict" else inferPhase(root, verdict, review_thread_id, failure_code, legacy_pre_review_transport);
    const review_attempt_exists = boolFieldAny(root, &.{ "reviewAttemptExists", "review_attempt_exists" }) orelse (review_thread_id != null);
    const tuple_verdict_exists = boolFieldAny(root, &.{ "tupleVerdictExists", "tuple_verdict_exists" }) orelse (stored_terminal.tuple_bound or tupleBoundVerdict(root, verdict, base_sha, head_sha, target_fingerprint));
    const explicit_backend_class = (if (verdict) |v| nullableStringAny(v, &.{ "backendClass", "backend_class" }) else null) orelse nullableStringAny(root, &.{ "backendClass", "backend_class" });
    const backend_class = explicit_backend_class orelse if (optEql(failure_code, "pre_review_lane_transport_lost")) "cas-lane" else storedSessionBackendClass(root, ctx.default_backend_class);
    const record_path = nullableStringAny(root, &.{ "recordPath", "record_path" }) orelse if (verdict) |v| nullableStringAny(v, &.{ "recordPath", "record_path" }) else null;
    const event_log_path = nullableStringAny(root, &.{ "eventLogPath", "event_log_path" }) orelse if (verdict) |v| nullableStringAny(v, &.{ "eventLogPath", "event_log_path" }) else null;
    const finding_count = if (verdict) |v| intFieldAny(v, &.{ "findingCount", "finding_count" }) orelse 0 else intFieldAny(root, &.{ "findingCount", "finding_count" }) orelse stored_terminal.finding_count orelse 0;

    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putStringOrNull(&row, "session_id", nonEmpty(ctx.session_id));
    try row.putStaticKey("source_path", .{ .string = ctx.source_path });
    try putStringOrNull(&row, "receipt_path", record_path orelse if (std.mem.eql(u8, ctx.command_surface, "receipt")) ctx.source_path else null);
    try putStringOrNull(&row, "cwd", nullableStringAny(root, &.{ "cwd", "workdir" }) orelse ctx.cwd);
    try row.putStaticKey("command_surface", .{ .string = ctx.command_surface });
    try row.putStaticKey("surface", .{ .string = surface });
    try row.putStaticKey("backend_class", .{ .string = backend_class });
    try row.putStaticKey("review_attempt_phase", .{ .string = phase });
    try row.putStaticKey("review_attempt_exists", .{ .bool = review_attempt_exists });
    try row.putStaticKey("tuple_verdict_exists", .{ .bool = tuple_verdict_exists });
    try putStringOrNull(&row, "failure_code", failure_code);
    try putStringOrNull(&row, "failure_class", nullableStringAny(root, &.{ "failureClass", "failure_class" }) orelse failureClassForCode(failure_code));
    try putBoolOrNull(&row, "retryable_same_tuple_now", boolFieldAny(root, &.{ "retryableSameTupleNow", "retryable_same_tuple_now" }));
    try putStringOrNull(&row, "lane_id", nullableStringAny(root, &.{ "laneId", "lane_id" }));
    try putIntOrNull(&row, "managed_server_pid", intFieldAny(root, &.{ "managedServerPid", "managed_server_pid" }));
    try putStringOrNull(&row, "managed_server_listen_url", nullableStringAny(root, &.{ "managedServerListenUrl", "managed_server_listen_url" }));
    try putStringOrNull(&row, "server_exit_status", nullableStringAny(root, &.{ "serverExitStatus", "server_exit_status" }));
    try putStringOrNull(&row, "stderr_log_path", nullableStringAny(root, &.{ "stderrLogPath", "stderr_log_path", "managedServerStderrLogPath", "managed_server_stderr_log_path" }));
    try row.putStaticKey("review_count", .{ .int = review_count });
    try putStringOrNull(&row, "last_review_thread_id", last_review_thread_id);
    try putStringOrNull(&row, "review_thread_id", review_thread_id);
    try putStringOrNull(&row, "review_turn_id", review_turn_id);
    try putStringOrNull(&row, "base_sha", base_sha);
    try putStringOrNull(&row, "head_sha", head_sha);
    try putStringOrNull(&row, "target_fingerprint", target_fingerprint);
    try putStringOrNull(&row, "review_verdict_status", verdict_status);
    try row.putStaticKey("finding_count", .{ .int = finding_count });
    try row.putStaticKey("account_resource_signal", .{ .bool = accountResourceSignal(root, verdict) });
    try row.putStaticKey("transport_signal", .{ .bool = transportSignal(failure_code, nullableStringAny(root, &.{ "failureClass", "failure_class" })) });
    try putStringOrNull(&row, "record_path", record_path);
    try putStringOrNull(&row, "event_log_path", event_log_path);
    try putStringOrNull(&row, "review_broker_action", broker_action);
    try putStringOrNull(&row, "review_broker_reason", broker_reason);
    return row;
}

fn classifyCasRerObject(allocator: std.mem.Allocator, root: std.json.ObjectMap, ctx: ClassifyContext) !query.Row {
    const command = objectField(root, "command");
    const broker = if (command) |cmd| objectField(cmd, "brokerDecision") else null;
    const tuple = objectField(root, "tuple");
    const attempt = objectField(root, "attempt");
    const verdict = objectField(root, "verdict");
    const failure = objectField(root, "failure");
    const principal = objectField(root, "principal");
    const attachments = objectField(root, "attachments");

    const record_id = nullableString(root, "recordId");
    const raw_status = if (verdict) |value| nullableString(value, "status") else null;
    const backend_class =
        (if (command) |cmd| nullableString(cmd, "sourceBackendClass") else null) orelse
        (if (command) |cmd| nullableString(cmd, "backendSelected") else null) orelse
        ctx.default_backend_class;
    const command_surface = if (command) |cmd| nullableString(cmd, "surface") orelse ctx.command_surface else ctx.command_surface;
    const raw_broker_action = if (broker) |value| nullableString(value, "action") else null;
    const raw_broker_reason = if (broker) |value| nullableString(value, "reason") else null;
    const broker_action = if (optEql(command_surface, "run")) raw_broker_action else null;
    const broker_reason = if (broker_action != null) raw_broker_reason else null;
    const failure_code = if (failure) |value| nullableString(value, "failureCode") else null;
    const failure_class = (if (failure) |value| nullableString(value, "failureClass") else null) orelse failureClassForCode(failure_code);
    const review_thread_id = if (attempt) |value| nullableString(value, "reviewThreadId") else null;
    const review_turn_id = if (attempt) |value| nullableString(value, "reviewTurnId") else null;
    const phase = if (attempt) |value| nullableString(value, "phase") else null;
    const attempt_exists = if (attempt) |value| boolField(value, "exists") orelse (review_thread_id != null) else false;
    const raw_tuple_verdict_exists = if (verdict) |value| boolField(value, "tupleVerdictExists") orelse false else false;
    const finding_count = if (verdict) |value| intField(value, "findingCount") orelse 0 else 0;
    const principal_kind = if (principal) |value| nullableString(value, "kind") else null;
    const principal_proof_usable = casRerPrincipalProofUsable(principal);
    const principal_reduced = if (principal) |value| boolField(value, "reduced") orelse optEql(principal_kind, "reduced") else false;
    const principal_fallback_used = if (principal) |value| boolField(value, "fallbackUsed") orelse false else false;
    const terminal_status = optEql(raw_status, "clean") or optEql(raw_status, "findings");
    const principal_unusable_terminal = raw_tuple_verdict_exists and terminal_status and !principal_proof_usable;
    const unbound_terminal_status = !raw_tuple_verdict_exists and terminal_status;
    const tuple_verdict_exists = raw_tuple_verdict_exists and !principal_unusable_terminal;
    const status = if (principal_unusable_terminal) "review_untrusted_source" else if (unbound_terminal_status) "incomplete" else raw_status;
    const record_path = if (attempt) |value| nullableString(value, "recordPath") else null;
    const event_log_path =
        (if (attempt) |value| nullableString(value, "eventLogPath") else null) orelse
        (if (attachments) |value| nullableString(value, "eventLog") else null);

    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putStringOrNull(&row, "session_id", nonEmpty(ctx.session_id));
    try row.putStaticKey("source_path", .{ .string = ctx.source_path });
    try putStringOrNull(&row, "receipt_path", ctx.source_path);
    try putStringOrNull(&row, "record_id", record_id);
    try row.putStaticKey("canonical_source", .{ .string = "cas_review_evidence_ledger" });
    try putStringOrNull(&row, "canonical_status", status);
    try putStringOrNull(&row, "parent_visible_status", null);
    try putStringOrNull(&row, "cwd", if (tuple) |value| nullableString(value, "repoRealpath") else ctx.cwd);
    try row.putStaticKey("command_surface", .{ .string = command_surface });
    try row.putStaticKey("surface", .{ .string = "cas_review_evidence_record" });
    try row.putStaticKey("backend_class", .{ .string = backend_class });
    try putStringOrNull(&row, "principal_kind", principal_kind);
    try row.putStaticKey("principal_proof_usable", .{ .bool = principal_proof_usable });
    try row.putStaticKey("principal_reduced", .{ .bool = principal_reduced });
    try row.putStaticKey("principal_fallback_used", .{ .bool = principal_fallback_used });
    try row.putStaticKey("review_attempt_phase", .{ .string = phase orelse "pre_lane_start" });
    try row.putStaticKey("review_attempt_exists", .{ .bool = attempt_exists });
    try row.putStaticKey("tuple_verdict_exists", .{ .bool = tuple_verdict_exists });
    try putStringOrNull(&row, "failure_code", failure_code);
    try putStringOrNull(&row, "failure_class", failure_class);
    try putBoolOrNull(&row, "retryable_same_tuple_now", if (failure) |value| boolField(value, "retryableSameTupleNow") else null);
    try putStringOrNull(&row, "lane_id", null);
    try putIntOrNull(&row, "managed_server_pid", null);
    try putStringOrNull(&row, "managed_server_listen_url", null);
    try putStringOrNull(&row, "server_exit_status", null);
    try putStringOrNull(&row, "stderr_log_path", if (attachments) |value| nullableString(value, "stderr") else null);
    try row.putStaticKey("review_count", .{ .int = 0 });
    try putStringOrNull(&row, "last_review_thread_id", null);
    try putStringOrNull(&row, "review_thread_id", review_thread_id);
    try putStringOrNull(&row, "review_turn_id", review_turn_id);
    try putStringOrNull(&row, "base_sha", if (tuple) |value| nullableString(value, "baseSha") else null);
    try putStringOrNull(&row, "head_sha", if (tuple) |value| nullableString(value, "headSha") else null);
    try putStringOrNull(&row, "target_fingerprint", if (tuple) |value| nullableString(value, "targetFingerprint") else null);
    try putStringOrNull(&row, "review_verdict_status", status);
    try row.putStaticKey("finding_count", .{ .int = finding_count });
    try row.putStaticKey("account_resource_signal", .{ .bool = optEql(status, "account_resource_exhausted") or optEql(failure_code, "account_resource_exhausted") });
    try row.putStaticKey("transport_signal", .{ .bool = optEql(status, "transport_failure") or transportSignal(failure_code, failure_class) });
    try putStringOrNull(&row, "record_path", record_path orelse ctx.source_path);
    try putStringOrNull(&row, "event_log_path", event_log_path);
    try putStringOrNull(&row, "review_broker_action", broker_action);
    try putStringOrNull(&row, "review_broker_reason", broker_reason);
    return row;
}

fn summarize(rows: []const query.Row) Summary {
    var out = Summary{ .row_count = @intCast(rows.len) };
    var has_tuple_verdict = false;
    var has_lane_tuple_verdict = false;
    var has_pre_review_failure = false;
    var has_degraded = false;

    for (rows) |row| {
        const failure_code = scalarString(row, "failure_code");
        const phase = scalarString(row, "review_attempt_phase");
        const status = scalarString(row, "review_verdict_status");
        const backend = scalarString(row, "backend_class");
        const command_surface = scalarString(row, "command_surface") orelse "";
        const surface = scalarString(row, "surface");
        const broker_action = scalarString(row, "review_broker_action");
        const attempt_exists = scalarBool(row, "review_attempt_exists");
        const tuple_exists = scalarBool(row, "tuple_verdict_exists");
        const finding_count = scalarInt(row, "finding_count");

        if (broker_action != null or std.mem.indexOf(u8, command_surface, "review_session run") != null) out.broker_run_count += 1;
        if (optEql(broker_action, "auto_replaced_dead_transport") or optEql(broker_action, "replaced_dead_transport")) out.broker_auto_replaced_dead_transport_count += 1;
        if (optEql(broker_action, "attached_existing")) out.broker_attached_existing_count += 1;
        if (optEql(broker_action, "blocked_live_attempt") or optEql(broker_action, "blocked_live")) out.broker_blocked_live_count += 1;
        if (optEql(surface, "manual_recovery_command")) out.manual_recovery_command_count += 1;

        if (optEql(failure_code, "pre_review_lane_transport_lost")) {
            out.pre_review_lane_transport_lost_count += 1;
            has_pre_review_failure = true;
        }
        if (scalarBool(row, "transport_signal") and attempt_exists) {
            out.review_attempt_transport_failure_count += 1;
            has_degraded = true;
        }
        if (optEql(status, "findings")) out.completed_findings_count += 1;
        if (optEql(status, "clean")) out.completed_clean_count += 1;
        if (optEql(status, "account_resource_exhausted") or optEql(failure_code, "account_resource_exhausted") or scalarBool(row, "account_resource_signal")) {
            out.account_resource_exhausted_count += 1;
            has_degraded = true;
        }
        if ((optEql(status, "timeout") or optEql(phase, "review_waiting")) and attempt_exists) out.timeout_with_handle_count += 1;
        if (optEql(failure_code, "duplicate_prevented")) out.duplicate_prevented_count += 1;
        if (std.mem.indexOf(u8, backend orelse "", "cas-start-wait") != null or std.mem.indexOf(u8, backend orelse "", "cas-native-fallback") != null) {
            if (tuple_exists) out.start_wait_normalized_count += 1 else out.start_wait_unormalized_count += 1;
            has_degraded = true;
        }
        if (tuple_exists and (optEql(status, "clean") or optEql(status, "findings"))) {
            has_tuple_verdict = true;
            if (optEql(backend, "cas-lane")) has_lane_tuple_verdict = true;
            if (finding_count > 0) out.completed_findings_count += 0;
        }
    }

    out.lane_backend_status = if (has_degraded or (has_pre_review_failure and has_tuple_verdict))
        "degraded"
    else if (has_lane_tuple_verdict)
        "available"
    else if (has_pre_review_failure)
        "failing_pre_review"
    else if (has_tuple_verdict)
        "degraded"
    else
        "unavailable";
    return out;
}

fn manualRecoveryCommand(command_surface: []const u8) bool {
    return std.mem.indexOf(u8, command_surface, "review_session lock") != null or
        std.mem.indexOf(u8, command_surface, "review_session receipt") != null or
        std.mem.indexOf(u8, command_surface, "receipt normalize") != null or
        std.mem.indexOf(u8, command_surface, "lock gate") != null or
        std.mem.indexOf(u8, command_surface, "--review-lock-override") != null;
}

fn inferPhase(
    root: std.json.ObjectMap,
    verdict: ?std.json.ObjectMap,
    review_thread_id: ?[]const u8,
    failure_code: ?[]const u8,
    legacy_pre_review_transport: bool,
) []const u8 {
    _ = failure_code;
    if (verdict != null) return "normalized_verdict";
    if (review_thread_id != null) {
        if (boolField(root, "timedOut") orelse false) return "review_waiting";
        if (terminalStatus(nullableString(root, "turnStatus"))) return "review_terminal";
        return "review_started";
    }
    if (legacy_pre_review_transport) return "pre_review_start";
    return "pre_lane_start";
}

fn tupleBoundVerdict(root: std.json.ObjectMap, verdict: ?std.json.ObjectMap, base: ?[]const u8, head: ?[]const u8, fingerprint: ?[]const u8) bool {
    const v = verdict orelse root;
    return base != null and head != null and fingerprint != null and
        optEql(nullableStringAny(v, &.{ "baseSha", "base_sha" }), base.?) and
        optEql(nullableStringAny(v, &.{ "headSha", "head_sha" }), head.?) and
        optEql(nullableStringAny(v, &.{ "targetFingerprint", "target_fingerprint" }), fingerprint.?);
}

fn reviewVerdictStatusRoot(root: std.json.ObjectMap) ?[]const u8 {
    const status = nullableString(root, "status") orelse return null;
    if (isKnownReviewVerdictStatus(status)) return status;
    return null;
}

fn isKnownReviewVerdictStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "clean") or
        std.mem.eql(u8, status, "findings") or
        std.mem.eql(u8, status, "timeout") or
        std.mem.eql(u8, status, "pre_review_transport_failure") or
        std.mem.eql(u8, status, "review_transport_failure") or
        std.mem.eql(u8, status, "account_resource_exhausted") or
        std.mem.eql(u8, status, "parse_mismatch") or
        std.mem.eql(u8, status, "review_output_missing") or
        std.mem.eql(u8, status, "review_untrusted_source") or
        std.mem.eql(u8, status, "incomplete") or
        std.mem.eql(u8, status, "no_attempt") or
        std.mem.eql(u8, status, "transport_failure");
}

const StoredTerminalProjection = struct {
    status: ?[]const u8 = null,
    finding_count: ?i64 = null,
    tuple_bound: bool = false,
};

fn storedTerminalProjection(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    base: ?[]const u8,
    head: ?[]const u8,
    fingerprint: ?[]const u8,
) StoredTerminalProjection {
    if (!optEql(nullableString(root, "terminal_review_result_source"), "rollout_exited_review_mode")) return .{};
    if (!terminalStatus(nullableString(root, "last_observed_status"))) return .{};
    const result_json = nullableString(root, "terminal_review_result_json") orelse return .{};

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch return .{};
    defer parsed.deinit();
    const result = object(parsed.value) orelse return .{};
    const finding_count: i64 = if (result.get("findings")) |value| switch (value) {
        .array => |arr| @intCast(arr.items.len),
        else => 0,
    } else 0;

    const tuple_bound = base != null and head != null and fingerprint != null and
        nullableStringAny(root, &.{ "reviewThreadId", "review_thread_id" }) != null;
    return .{
        .status = if (finding_count > 0) "findings" else "clean",
        .finding_count = finding_count,
        .tuple_bound = tuple_bound,
    };
}

fn storedSessionBackendClass(root: std.json.ObjectMap, fallback: []const u8) []const u8 {
    if (nullableStringAny(root, &.{ "laneId", "lane_id" }) != null) return "cas-lane";
    if (std.mem.startsWith(u8, nullableString(root, "transport_selection_reason") orelse "", "persistent_review_lane")) return "cas-lane";
    if (optEql(nullableString(root, "terminal_fallback_transport"), "native-review")) return "cas-native-fallback";
    if (nullableString(root, "terminal_review_result_source") != null and nullableStringAny(root, &.{ "reviewThreadId", "review_thread_id" }) != null) return "cas-start-wait";
    return fallback;
}

fn accountResourceSignal(root: std.json.ObjectMap, verdict: ?std.json.ObjectMap) bool {
    if (optEql(nullableStringAny(root, &.{ "failureCode", "failure_code" }), "account_resource_exhausted")) return true;
    if (verdict) |v| {
        if (optEql(nullableString(v, "status"), "account_resource_exhausted")) return true;
        if (optEql(nullableStringAny(v, &.{ "failureCode", "failure_code" }), "account_resource_exhausted")) return true;
    }
    return containsAccountSignal(root);
}

fn containsAccountSignal(obj: std.json.ObjectMap) bool {
    var it = obj.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .string => |text| {
                if (std.mem.indexOf(u8, text, "usageLimitExceeded") != null) return true;
                if (std.ascii.indexOfIgnoreCase(text, "rate limit exceeded") != null) return true;
                if (std.ascii.indexOfIgnoreCase(text, "quota exceeded") != null) return true;
                if (std.ascii.indexOfIgnoreCase(text, "account limit") != null) return true;
            },
            .object => |nested| if (containsAccountSignal(nested)) return true,
            else => {},
        }
    }
    return false;
}

fn transportSignal(failure_code: ?[]const u8, failure_class: ?[]const u8) bool {
    if (optEql(failure_class, "transport") or optEql(failure_class, "transport_pre_review") or optEql(failure_class, "transport_review_attempt")) return true;
    const code = failure_code orelse return false;
    return std.mem.indexOf(u8, code, "transport") != null or std.mem.indexOf(u8, code, "lane_transport") != null;
}

fn rowMatchesFilters(row: query.Row, params: Params) bool {
    if (params.session_id) |want| {
        if (!optEql(scalarString(row, "session_id"), want)) return false;
    }
    if (params.repo) |want| {
        const cwd = scalarString(row, "cwd") orelse "";
        if (!pathMatchesScope(cwd, want)) return false;
    }
    if (params.workdir) |want| {
        const cwd = scalarString(row, "cwd") orelse "";
        if (!pathMatchesScope(cwd, want)) return false;
    }
    if (params.base_sha) |want| if (!optEql(scalarString(row, "base_sha"), want)) return false;
    if (params.head_sha) |want| if (!optEql(scalarString(row, "head_sha"), want)) return false;
    if (params.target_fingerprint) |want| if (!optEql(scalarString(row, "target_fingerprint"), want)) return false;
    if (params.exclude_current_session_id) |current| {
        if (optEql(scalarString(row, "session_id"), current)) return false;
    }
    return true;
}

fn pathMatchesScope(path: []const u8, scope: []const u8) bool {
    if (scope.len == 0) return false;
    var trimmed_scope = scope;
    while (trimmed_scope.len > 1 and trimmed_scope[trimmed_scope.len - 1] == '/') {
        trimmed_scope = trimmed_scope[0 .. trimmed_scope.len - 1];
    }
    if (std.mem.eql(u8, path, trimmed_scope)) return true;
    if (!std.mem.startsWith(u8, path, trimmed_scope)) return false;
    return path.len > trimmed_scope.len and path[trimmed_scope.len] == '/';
}

fn claimDedupeKey(
    allocator: std.mem.Allocator,
    row: query.Row,
    source_path: []const u8,
    fallback: []const u8,
    dedupe: *std.StringHashMap(void),
) !bool {
    const key_value = scalarString(row, "record_path") orelse scalarString(row, "event_log_path") orelse scalarString(row, "review_thread_id") orelse fallback;
    const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ source_path, key_value });
    errdefer allocator.free(key);
    if (dedupe.contains(key)) {
        allocator.free(key);
        return false;
    }
    try dedupe.put(key, {});
    return true;
}

fn looksLikeCasReviewCommand(cmd: []const u8) bool {
    return std.mem.indexOf(u8, cmd, "cas review ") != null or
        std.mem.indexOf(u8, cmd, "cas review_session") != null or
        std.mem.indexOf(u8, cmd, "cas_review_session") != null or
        std.mem.indexOf(u8, cmd, "review_session") != null;
}

fn looksLikeReceiptObject(root: std.json.ObjectMap) bool {
    if (nullableString(root, "surface")) |surface| {
        if (optEql(surface, "normalize") or optEql(surface, "runner")) return true;
    }
    if (objectField(root, "reviewVerdict") != null) return true;
    if (objectField(root, "reviewBrokerDecision") != null) return true;
    if (nullableStringAny(root, &.{ "reviewThreadId", "review_thread_id" }) != null) return true;
    if (nullableStringAny(root, &.{ "reviewAttemptPhase", "review_attempt_phase" }) != null) return true;
    if (nullableStringAny(root, &.{ "failureCode", "failure_code" }) != null) return true;
    if (intFieldAny(root, &.{ "reviewCount", "review_count" }) != null) return true;
    if (nullableStringAny(root, &.{ "baseSha", "base_sha" }) != null and nullableStringAny(root, &.{ "headSha", "head_sha" }) != null and nullableStringAny(root, &.{ "targetFingerprint", "target_fingerprint" }) != null) return true;
    if (nullableString(root, "status")) |status| {
        return optEql(status, "clean") or
            optEql(status, "findings") or
            optEql(status, "timeout") or
            optEql(status, "transport_failure") or
            optEql(status, "pre_review_transport_failure") or
            optEql(status, "review_transport_failure") or
            optEql(status, "account_resource_exhausted") or
            optEql(status, "parse_mismatch") or
            optEql(status, "incomplete") or
            optEql(status, "no_attempt");
    }
    return false;
}

fn overrideFlagsSummary(root: std.json.ObjectMap) ?[]const u8 {
    const value = root.get("overrideFlags") orelse return null;
    return switch (value) {
        .array => |array| if (array.items.len == 0) null else switch (array.items[0]) {
            .string => |text| text,
            else => "present",
        },
        else => null,
    };
}

fn backendFromCommand(cmd: []const u8) []const u8 {
    if (std.mem.indexOf(u8, cmd, "lane") != null) return "cas-lane";
    if (std.mem.indexOf(u8, cmd, "start") != null and std.mem.indexOf(u8, cmd, "--wait") != null) return "cas-start-wait";
    return "cas-receipt-normalized";
}

fn findJsonObject(text: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < text.len and text[cursor.*] != '{') : (cursor.* += 1) {}
    if (cursor.* >= text.len) return null;
    const start = cursor.*;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                cursor.* = i + 1;
                return text[start .. i + 1];
            }
        }
    }
    cursor.* = text.len;
    return null;
}

fn globMatch(pattern: []const u8, name: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, name);
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1 ..];
    return std.mem.startsWith(u8, name, prefix) and std.mem.endsWith(u8, name, suffix);
}

fn withinWindow(timestamp: []const u8, params: Params) bool {
    if (params.since_ms != null or params.until_ms != null) {
        const ts_ms = time_utils.parseIsoTimestampMillis(timestamp) orelse return false;
        if (params.since_ms) |since| if (ts_ms < since) return false;
        if (params.until_ms) |until| if (ts_ms > until) return false;
        return true;
    }
    if (params.since) |s| if (std.mem.order(u8, timestamp, s) == .lt) return false;
    if (params.until) |u| if (std.mem.order(u8, timestamp, u) == .gt) return false;
    return true;
}

fn terminalStatus(status: ?[]const u8) bool {
    return optEql(status, "completed") or optEql(status, "failed") or optEql(status, "cancelled") or optEql(status, "canceled");
}

fn object(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn objectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return object(value);
}

fn casRerPrincipalProofUsable(principal: ?std.json.ObjectMap) bool {
    const principal_obj = principal orelse return false;
    if (boolField(principal_obj, "proofUsable") != true) return false;
    if (!optEql(nullableString(principal_obj, "kind"), "strong")) return false;
    if (boolField(principal_obj, "reduced") != false) return false;
    if (boolField(principal_obj, "fallbackUsed") != false) return false;
    if (optEql(nullableString(principal_obj, "source"), "cas-native-fallback")) return false;
    const fingerprint = nullableString(principal_obj, "accountFingerprint") orelse return false;
    if (fingerprint.len == 0) return false;
    return !std.mem.eql(u8, fingerprint, "unknown-account");
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn nullableString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| if (text.len == 0) null else text,
        .null => null,
        else => null,
    };
}

fn nullableStringAny(obj: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (nullableString(obj, key)) |value| return value;
    }
    return null;
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |v| v,
        else => null,
    };
}

fn boolFieldAny(obj: std.json.ObjectMap, keys: []const []const u8) ?bool {
    for (keys) |key| {
        if (boolField(obj, key)) |value| return value;
    }
    return null;
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |v| v,
        else => null,
    };
}

fn intFieldAny(obj: std.json.ObjectMap, keys: []const []const u8) ?i64 {
    for (keys) |key| {
        if (intField(obj, key)) |value| return value;
    }
    return null;
}

fn putStringOrNull(row: *query.Row, key: []const u8, value: ?[]const u8) !void {
    if (value) |text| try row.putStaticKey(key, .{ .string = text }) else try row.putStaticKey(key, .null);
}

fn putBoolOrNull(row: *query.Row, key: []const u8, value: ?bool) !void {
    if (value) |v| try row.putStaticKey(key, .{ .bool = v }) else try row.putStaticKey(key, .null);
}

fn putIntOrNull(row: *query.Row, key: []const u8, value: ?i64) !void {
    if (value) |v| try row.putStaticKey(key, .{ .int = v }) else try row.putStaticKey(key, .null);
}

fn failureClassForCode(code: ?[]const u8) ?[]const u8 {
    const value = code orelse return null;
    if (optEql(value, "pre_review_lane_transport_lost")) return "transport_pre_review";
    if (optEql(value, "review_transport_lost") or optEql(value, "lane_transport_lost")) return "transport_review_attempt";
    if (optEql(value, "account_resource_exhausted")) return "account_resource";
    if (optEql(value, "wait_timed_out")) return "timeout";
    if (std.mem.indexOf(u8, value, "parse") != null) return "parse";
    if (std.mem.indexOf(u8, value, "output") != null) return "review_output";
    return null;
}

fn canonicalVerdictStatus(status: ?[]const u8, failure_code: ?[]const u8, review_thread_id: ?[]const u8) ?[]const u8 {
    const value = status orelse return null;
    if (optEql(value, "no_attempt")) {
        if (optEql(failure_code, "pre_review_lane_transport_lost")) return "pre_review_transport_failure";
        return "incomplete";
    }
    if (optEql(value, "transport_failure")) {
        return if (review_thread_id != null) "review_transport_failure" else "pre_review_transport_failure";
    }
    return value;
}

fn scalarString(row: query.Row, key: []const u8) ?[]const u8 {
    return switch (row.valueOrNull(key)) {
        .string => |text| text,
        else => null,
    };
}

fn scalarBool(row: query.Row, key: []const u8) bool {
    return switch (row.valueOrNull(key)) {
        .bool => |v| v,
        else => false,
    };
}

fn scalarInt(row: query.Row, key: []const u8) i64 {
    return switch (row.valueOrNull(key)) {
        .int => |v| v,
        else => 0,
    };
}

fn nonEmpty(text: []const u8) ?[]const u8 {
    return if (text.len == 0) null else text;
}

fn optEql(value: ?[]const u8, want: []const u8) bool {
    return if (value) |v| std.mem.eql(u8, v, want) else false;
}

test "legacy lane transport loss is pre-review failure" {
    var row = try classifyReceiptText(std.testing.allocator,
        \\{"failureCode":"lane_transport_lost","reviewCount":0,"lastReviewThreadId":null,"lastHeadSha":null,"reviewThreadId":null}
    , .{
        .session_id = "sess",
        .cwd = "/repo",
        .command_surface = "cas review_session lane review",
        .source_path = "/tmp/session.jsonl",
        .default_backend_class = "cas-lane",
    });
    defer row.deinit();

    try std.testing.expectEqualStrings("pre_review_lane_transport_lost", scalarString(row, "failure_code").?);
    try std.testing.expectEqualStrings("pre_review_start", scalarString(row, "review_attempt_phase").?);
    try std.testing.expect(!scalarBool(row, "review_attempt_exists"));
}

test "tuple-bound review verdict projects normalized verdict" {
    var row = try classifyReceiptText(std.testing.allocator,
        \\{"reviewThreadId":"thr_1","baseSha":"b","headSha":"h","targetFingerprint":"t","reviewVerdict":{"status":"clean","clean":true,"findingCount":0,"failureCode":null,"baseSha":"b","headSha":"h","targetFingerprint":"t","reviewThreadId":"thr_1","backendClass":"cas-start-wait"}}
    , .{
        .session_id = "sess",
        .cwd = "/repo",
        .command_surface = "cas review_session start --wait",
        .source_path = "/tmp/start-wait.json",
        .default_backend_class = "cas-start-wait",
    });
    defer row.deinit();

    try std.testing.expectEqualStrings("normalized_verdict", scalarString(row, "review_attempt_phase").?);
    try std.testing.expect(scalarBool(row, "review_attempt_exists"));
    try std.testing.expect(scalarBool(row, "tuple_verdict_exists"));

    const summary = summarize(&.{row});
    try std.testing.expectEqual(@as(i64, 1), summary.completed_clean_count);
    try std.testing.expectEqualStrings("degraded", summary.lane_backend_status);
}

test "explicit false tuple verdict flag is preserved despite tuple fields" {
    var row = try classifyReceiptText(std.testing.allocator,
        \\{"reviewThreadId":"thr_started","reviewAttemptPhase":"review_started","reviewAttemptExists":true,"tupleVerdictExists":false,"baseSha":"b","headSha":"h","targetFingerprint":"t"}
    , .{
        .session_id = "sess",
        .cwd = "/repo",
        .command_surface = "cas review_session lane smoke",
        .source_path = "/tmp/no-wait-smoke.json",
        .default_backend_class = "cas-lane",
    });
    defer row.deinit();

    try std.testing.expectEqualStrings("review_started", scalarString(row, "review_attempt_phase").?);
    try std.testing.expect(scalarBool(row, "review_attempt_exists"));
    try std.testing.expect(!scalarBool(row, "tuple_verdict_exists"));
}

test "lane smoke command pass status is not a review verdict" {
    var row = try classifyReceiptText(std.testing.allocator,
        \\{"action":"lane-smoke","status":"pass","smokeStatus":"passed","reviewThreadId":"thr_started","reviewAttemptPhase":"review_started","reviewAttemptExists":true,"tupleVerdictExists":false,"baseSha":"b","headSha":"h","targetFingerprint":"t"}
    , .{
        .session_id = "sess",
        .cwd = "/repo",
        .command_surface = "cas review_session lane smoke",
        .source_path = "/tmp/no-wait-smoke.json",
        .default_backend_class = "cas-lane",
    });
    defer row.deinit();

    try std.testing.expectEqualStrings("review_started", scalarString(row, "review_attempt_phase").?);
    try std.testing.expect(scalarBool(row, "review_attempt_exists"));
    try std.testing.expect(!scalarBool(row, "tuple_verdict_exists"));
    try std.testing.expectEqual(@as(?[]const u8, null), scalarString(row, "review_verdict_status"));
}

test "stored terminal session record projects tuple-bound clean review verdict" {
    var row = try classifyReceiptText(std.testing.allocator,
        \\{"schema_version":"CAS-RS-record-v1","last_observed_status":"completed","terminal_review_result_source":"rollout_exited_review_mode","terminal_review_result_json":"{\"findings\":[],\"overallCorrectness\":\"patch is correct\"}","review_thread_id":"thr_1","review_turn_id":"turn_1","base_sha":"b","head_sha":"h","target_fingerprint":"t","event_log_path":"/tmp/thr_1.events.ndjson"}
    , .{
        .session_id = "",
        .cwd = null,
        .command_surface = "receipt",
        .source_path = "/tmp/thr_1.json",
        .default_backend_class = "cas-receipt-normalized",
    });
    defer row.deinit();

    try std.testing.expectEqualStrings("cas-start-wait", scalarString(row, "backend_class").?);
    try std.testing.expectEqualStrings("normalized_verdict", scalarString(row, "review_attempt_phase").?);
    try std.testing.expect(scalarBool(row, "review_attempt_exists"));
    try std.testing.expect(scalarBool(row, "tuple_verdict_exists"));
    try std.testing.expectEqualStrings("clean", scalarString(row, "review_verdict_status").?);
    try std.testing.expectEqual(@as(i64, 0), scalarInt(row, "finding_count"));
}

test "stored terminal lane session record preserves lane backend" {
    var row = try classifyReceiptText(std.testing.allocator,
        \\{"schema_version":"CAS-RS-record-v1","transport_selection_reason":"persistent_review_lane","last_observed_status":"completed","terminal_review_result_source":"rollout_exited_review_mode","terminal_review_result_json":"{\"findings\":[],\"overallCorrectness\":\"patch is correct\"}","review_thread_id":"thr_lane","review_turn_id":"turn_lane","base_sha":"b","head_sha":"h","target_fingerprint":"t","event_log_path":"/tmp/thr_lane.events.ndjson"}
    , .{
        .session_id = "",
        .cwd = null,
        .command_surface = "receipt",
        .source_path = "/tmp/thr_lane.json",
        .default_backend_class = "cas-receipt-normalized",
    });
    defer row.deinit();

    try std.testing.expectEqualStrings("cas-lane", scalarString(row, "backend_class").?);
    try std.testing.expectEqualStrings("normalized_verdict", scalarString(row, "review_attempt_phase").?);
    try std.testing.expect(scalarBool(row, "tuple_verdict_exists"));
    try std.testing.expectEqualStrings("clean", scalarString(row, "review_verdict_status").?);
}

test "standard response item output is audited with top-level session meta" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(defaultIo(), .{ .sub_path = "session.jsonl", .data =
        \\{"type":"session_meta","timestamp":"2026-06-27T01:00:00Z","payload":{"id":"sess-standard"}}
        \\{"type":"response_item","timestamp":"2026-06-27T01:00:01Z","payload":{"type":"function_call","name":"exec_command","call_id":"call-1","arguments":"{\"cmd\":\"cas review_session start --wait --json\",\"cwd\":\"/repo\"}"}}
        \\{"type":"response_item","timestamp":"2026-06-27T01:00:02Z","payload":{"type":"function_call_output","call_id":"call-1","output":"{\"reviewThreadId\":\"thr_1\",\"baseSha\":\"b\",\"headSha\":\"h\",\"targetFingerprint\":\"t\",\"reviewVerdict\":{\"status\":\"clean\",\"clean\":true,\"findingCount\":0,\"failureCode\":null,\"baseSha\":\"b\",\"headSha\":\"h\",\"targetFingerprint\":\"t\",\"reviewThreadId\":\"thr_1\",\"backendClass\":\"cas-start-wait\"}}\n"}}
        \\
    });

    const root_abs = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "session.jsonl" });
    defer std.testing.allocator.free(path);

    var audit = try compile(std.testing.allocator, .{
        .root = root_abs,
        .path = path,
        .session_id = "sess-standard",
        .repo = "/repo",
    });
    defer audit.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), audit.rows.items.len);
    try std.testing.expectEqual(@as(i64, 1), audit.summary.completed_clean_count);
    try std.testing.expectEqual(@as(i64, 1), audit.summary.start_wait_normalized_count);
    try std.testing.expectEqualStrings("sess-standard", scalarString(audit.rows.items[0], "session_id").?);
}

test "brokered run output contributes broker summary counters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(defaultIo(), .{ .sub_path = "session.jsonl", .data =
        \\{"type":"session_meta","timestamp":"2026-06-27T01:00:00Z","payload":{"id":"sess-broker"}}
        \\{"type":"response_item","timestamp":"2026-06-27T01:00:01Z","payload":{"type":"function_call","name":"exec_command","call_id":"call-1","arguments":"{\"cmd\":\"cas review_session run --cwd /repo --base main --json\",\"cwd\":\"/repo\"}"}}
        \\{"type":"response_item","timestamp":"2026-06-27T01:00:02Z","payload":{"type":"function_call_output","call_id":"call-1","output":"{\"demo\":\"cas-review-session\",\"action\":\"run\",\"reviewBrokerDecision\":{\"version\":\"CAS-RBD-v1\",\"action\":\"auto_replaced_dead_transport\",\"reason\":\"dead\",\"reviewThreadId\":\"thr_1\",\"recordPath\":\"/tmp/review.json\",\"eventLogPath\":\"/tmp/review.events.ndjson\"},\"reviewThreadId\":\"thr_2\",\"baseSha\":\"b\",\"headSha\":\"h\",\"targetFingerprint\":\"t\",\"reviewVerdict\":{\"status\":\"clean\",\"clean\":true,\"findingCount\":0,\"failureCode\":null,\"baseSha\":\"b\",\"headSha\":\"h\",\"targetFingerprint\":\"t\",\"reviewThreadId\":\"thr_2\",\"backendClass\":\"cas-start-wait\"}}\n"}}
        \\
    });

    const root_abs = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "session.jsonl" });
    defer std.testing.allocator.free(path);

    var audit = try compile(std.testing.allocator, .{
        .root = root_abs,
        .path = path,
        .session_id = "sess-broker",
        .repo = "/repo",
    });
    defer audit.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), audit.rows.items.len);
    try std.testing.expectEqual(@as(i64, 1), audit.summary.broker_run_count);
    try std.testing.expectEqual(@as(i64, 1), audit.summary.broker_auto_replaced_dead_transport_count);
    try std.testing.expectEqualStrings("auto_replaced_dead_transport", scalarString(audit.rows.items[0], "review_broker_action").?);
}

test "manual recovery command uses output cwd and is counted once when output is receipt-shaped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(defaultIo(), .{ .sub_path = "session.jsonl", .data =
        \\{"type":"session_meta","timestamp":"2026-06-27T01:00:00Z","payload":{"id":"sess-manual"}}
        \\{"type":"response_item","timestamp":"2026-06-27T01:00:01Z","payload":{"type":"function_call","name":"exec_command","call_id":"call-1","arguments":"{\"cmd\":\"cas review_session lock gate --path tuple-lock.json --format json\"}"}}
        \\{"type":"event_msg","timestamp":"2026-06-27T01:00:02Z","payload":{"type":"exec_command_end","call_id":"call-1","cwd":"/repo","stdout":"","output":""}}
        \\{"type":"response_item","timestamp":"2026-06-27T01:00:03Z","payload":{"type":"function_call_output","call_id":"call-1","output":"{\"reviewThreadId\":\"thr_1\",\"baseSha\":\"b\",\"headSha\":\"h\",\"targetFingerprint\":\"t\",\"reviewVerdict\":{\"status\":\"clean\",\"clean\":true,\"findingCount\":0,\"failureCode\":null,\"baseSha\":\"b\",\"headSha\":\"h\",\"targetFingerprint\":\"t\",\"reviewThreadId\":\"thr_1\",\"backendClass\":\"cas-receipt-normalized\"}}\n"}}
        \\
    });

    const root_abs = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "session.jsonl" });
    defer std.testing.allocator.free(path);

    var audit = try compile(std.testing.allocator, .{
        .root = root_abs,
        .path = path,
        .session_id = "sess-manual",
        .repo = "/repo",
    });
    defer audit.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), audit.rows.items.len);
    try std.testing.expectEqual(@as(i64, 1), audit.summary.manual_recovery_command_count);
    try std.testing.expectEqualStrings("manual_recovery_command", scalarString(audit.rows.items[0], "surface").?);
    try std.testing.expectEqualStrings("/repo", scalarString(audit.rows.items[0], "cwd").?);
    try std.testing.expectEqualStrings("/repo", scalarString(audit.rows.items[1], "cwd").?);
}

test "basename receipt glob keeps handle-less receipts distinct and skips non-receipts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(defaultIo(), .{ .sub_path = "receipts.json", .data =
        \\{"type":"unrelated","status":"ok"}
        \\{"failureCode":"pre_review_lane_transport_lost","reviewAttemptPhase":"pre_review_start","baseSha":"b1","headSha":"h1","targetFingerprint":"t1"}
        \\{"failureCode":"pre_review_lane_transport_lost","reviewAttemptPhase":"pre_review_start","baseSha":"b2","headSha":"h2","targetFingerprint":"t2"}
        \\
    });

    const root_abs = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);

    var audit = try compile(std.testing.allocator, .{
        .root = root_abs,
        .receipt_globs = &.{"*.json"},
    });
    defer audit.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), audit.rows.items.len);
    try std.testing.expectEqual(@as(i64, 2), audit.summary.pre_review_lane_transport_lost_count);
}

test "smoke suite receipt expands final-window result rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(defaultIo(), .{ .sub_path = "suite.json", .data =
        \\{"suiteVersion":"CAS-RSS-v1","status":"pass","cwd":"/repo","runsRequested":2,"requiredConsecutivePasses":2,"maxConsecutivePasses":2,"persistentLaneCanonical":true,"canonicalReviewBackend":"cas-lane","results":[
        \\{"runId":"smoke-001","status":"pass","reviewVerdictStatus":"clean","reviewAttemptExists":true,"tupleVerdictExists":true,"laneId":"lane_1","reviewThreadId":"thr_1","recordPath":"/tmp/smoke-same-tuple.json","baseSha":"b","headSha":"h","targetFingerprint":"t"},
        \\{"runId":"smoke-002","status":"pass","reviewVerdictStatus":"clean","reviewAttemptExists":true,"tupleVerdictExists":true,"laneId":"lane_2","reviewThreadId":"thr_2","recordPath":"/tmp/smoke-same-tuple.json","baseSha":"b","headSha":"h","targetFingerprint":"t"}]}
    });
    const root_abs = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const suite_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "suite.json" });
    defer std.testing.allocator.free(suite_path);
    var row_audit = try compile(std.testing.allocator, .{
        .root = root_abs,
        .receipt_paths = &.{suite_path},
    });
    defer row_audit.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), row_audit.rows.items.len);
    try std.testing.expectEqualStrings("lane-smoke-suite", scalarString(row_audit.rows.items[0], "command_surface").?);
    try std.testing.expectEqualStrings("cas-lane", scalarString(row_audit.rows.items[0], "backend_class").?);
    try std.testing.expectEqualStrings("clean", scalarString(row_audit.rows.items[0], "review_verdict_status").?);
    try std.testing.expect(scalarBool(row_audit.rows.items[0], "review_attempt_exists"));
    try std.testing.expect(scalarBool(row_audit.rows.items[0], "tuple_verdict_exists"));
}

test "smoke artifact dedupe preserves same run ids across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const artifact =
        \\{"suiteVersion":"CAS-RSS-v1","status":"fail","cwd":"/repo","runsRequested":1,"requiredConsecutivePasses":1,"maxConsecutivePasses":0,"persistentLaneCanonical":false,"canonicalReviewBackend":"cas-start-wait-normalized","results":[
        \\{"runId":"smoke-001","status":"fail","failureCode":"pre_review_lane_transport_lost","reviewAttemptExists":false,"tupleVerdictExists":false,"reviewThreadId":null}]}
    ;
    try tmp.dir.writeFile(defaultIo(), .{ .sub_path = "suite-a.json", .data = artifact });
    try tmp.dir.writeFile(defaultIo(), .{ .sub_path = "suite-b.json", .data = artifact });

    const root_abs = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const suite_a_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "suite-a.json" });
    defer std.testing.allocator.free(suite_a_path);
    const suite_b_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "suite-b.json" });
    defer std.testing.allocator.free(suite_b_path);

    var row_audit = try compile(std.testing.allocator, .{
        .root = root_abs,
        .receipt_paths = &.{ suite_a_path, suite_b_path },
    });
    defer row_audit.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), row_audit.rows.items.len);
    try std.testing.expectEqual(@as(i64, 2), row_audit.summary.pre_review_lane_transport_lost_count);
}

test "smoke promotion receipt projects pre-review failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(defaultIo(), .{ .sub_path = "promotion.json", .data =
        \\{"promotionVersion":"CAS-RSP-v1","status":"not_promoted","cwd":"/tmp/repo","roundsRun":1,"requiredConsecutivePasses":2,"observedConsecutivePasses":1,"finalBackendPolicy":{"persistentLaneCanonical":false,"canonicalReviewBackend":"cas-start-wait-normalized"},"results":[
        \\{"runId":"smoke-001","status":"pass","reviewVerdictStatus":"clean","reviewAttemptExists":true,"tupleVerdictExists":true,"reviewThreadId":"thr_1"},
        \\{"runId":"smoke-002","status":"fail","failureCode":"pre_review_lane_transport_lost","reviewAttemptExists":false,"tupleVerdictExists":false,"reviewThreadId":null}]}
    });
    const root_abs = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const promotion_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "promotion.json" });
    defer std.testing.allocator.free(promotion_path);
    var row_audit = try compile(std.testing.allocator, .{
        .root = root_abs,
        .receipt_paths = &.{promotion_path},
    });
    defer row_audit.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), row_audit.rows.items.len);
    try std.testing.expectEqualStrings("lane-smoke-until-fixed", scalarString(row_audit.rows.items[1], "command_surface").?);
    try std.testing.expectEqualStrings("/tmp/repo", scalarString(row_audit.rows.items[1], "cwd").?);
    try std.testing.expectEqualStrings("pre_review_lane_transport_lost", scalarString(row_audit.rows.items[1], "failure_code").?);
    try std.testing.expectEqualStrings("pre_review_start", scalarString(row_audit.rows.items[1], "review_attempt_phase").?);
    try std.testing.expect(!scalarBool(row_audit.rows.items[1], "review_attempt_exists"));
    try std.testing.expectEqual(@as(i64, 1), row_audit.summary.pre_review_lane_transport_lost_count);
}

test "snake-case root verdict receipts are normalized" {
    var row = try classifyReceiptText(std.testing.allocator,
        \\{"status":"clean","backend_class":"cas-lane","finding_count":0,"base_sha":"b","head_sha":"h","target_fingerprint":"t","review_thread_id":"thr_1","review_turn_id":"turn_1","tuple_verdict_exists":true,"review_attempt_phase":"normalized_verdict"}
    , .{
        .session_id = "",
        .cwd = null,
        .command_surface = "receipt",
        .source_path = "/tmp/receipt.json",
        .default_backend_class = "cas-receipt-normalized",
    });
    defer row.deinit();

    try std.testing.expectEqualStrings("cas-lane", scalarString(row, "backend_class").?);
    try std.testing.expectEqualStrings("clean", scalarString(row, "review_verdict_status").?);
    try std.testing.expect(scalarBool(row, "review_attempt_exists"));
    try std.testing.expect(scalarBool(row, "tuple_verdict_exists"));

    const summary = summarize(&.{row});
    try std.testing.expectEqual(@as(i64, 1), summary.completed_clean_count);
    try std.testing.expectEqualStrings("available", summary.lane_backend_status);
}

test "CAS-RER findings record is canonical ledger evidence" {
    var row = try classifyReceiptText(std.testing.allocator,
        \\{"schema":"CAS-RER-v1","recordId":"rer_findings","createdAt":"2026-07-02T00:00:00Z","updatedAt":"2026-07-02T00:00:00Z","command":{"surface":"import","backendSelected":"imported-legacy","sourceBackendClass":"cas-lane","brokerDecision":{"action":"imported_legacy","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:attempt","phase":"normalized_verdict","reviewThreadId":"thr_findings","reviewTurnId":"turn_findings","recordPath":"/tmp/session.json","eventLogPath":"/tmp/events.ndjson"},"verdict":{"tupleVerdictExists":true,"status":"findings","clean":false,"findingCount":2,"findings":[{"title":"one"},{"title":"two"}]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"},"attachments":{"eventLog":"/tmp/events.ndjson","rawSessionRecord":"/tmp/session.json","rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":true,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    , .{
        .session_id = "",
        .cwd = null,
        .command_surface = "receipt",
        .source_path = "/tmp/rer.json",
        .default_backend_class = "cas-receipt-normalized",
    });
    defer row.deinit();

    try std.testing.expectEqualStrings("cas_review_evidence_ledger", scalarString(row, "canonical_source").?);
    try std.testing.expectEqualStrings("findings", scalarString(row, "canonical_status").?);
    try std.testing.expectEqualStrings("rer_findings", scalarString(row, "record_id").?);
    try std.testing.expectEqualStrings("findings", scalarString(row, "review_verdict_status").?);
    try std.testing.expectEqualStrings("thr_findings", scalarString(row, "review_thread_id").?);
    try std.testing.expectEqualStrings("base", scalarString(row, "base_sha").?);
    try std.testing.expectEqualStrings("head", scalarString(row, "head_sha").?);
    try std.testing.expectEqualStrings("fp", scalarString(row, "target_fingerprint").?);
    try std.testing.expectEqual(@as(i64, 2), scalarInt(row, "finding_count"));

    const summary = summarize(&.{row});
    try std.testing.expectEqual(@as(i64, 1), summary.completed_findings_count);
    try std.testing.expectEqual(@as(i64, 0), summary.timeout_with_handle_count);
}

test "CAS-RER unusable principal is not counted as completed evidence" {
    var row = try classifyReceiptText(std.testing.allocator,
        \\{"schema":"CAS-RER-v1","recordId":"rer_reduced","createdAt":"2026-07-02T00:00:00Z","updatedAt":"2026-07-02T00:00:00Z","command":{"surface":"import","backendSelected":"imported-legacy","sourceBackendClass":"cas-lane"},"tuple":{"repoRealpath":"/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp"},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr_reduced","reviewTurnId":"turn_reduced"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"reduced","proofUsable":false,"reduced":true,"fallbackUsed":false}}
    , .{
        .session_id = "",
        .cwd = null,
        .command_surface = "receipt",
        .source_path = "/tmp/rer-reduced.json",
        .default_backend_class = "cas-receipt-normalized",
    });
    defer row.deinit();

    try std.testing.expectEqualStrings("review_untrusted_source", scalarString(row, "canonical_status").?);
    try std.testing.expectEqualStrings("review_untrusted_source", scalarString(row, "review_verdict_status").?);
    try std.testing.expect(!scalarBool(row, "tuple_verdict_exists"));
    try std.testing.expect(!scalarBool(row, "principal_proof_usable"));
    try std.testing.expect(scalarBool(row, "principal_reduced"));

    const summary = summarize(&.{row});
    try std.testing.expectEqual(@as(i64, 0), summary.completed_clean_count);
    try std.testing.expectEqual(@as(i64, 0), summary.completed_findings_count);
}

test "CAS-RER proof usable principal requires account fingerprint" {
    var row = try classifyReceiptText(std.testing.allocator,
        \\{"schema":"CAS-RER-v1","recordId":"rer_missing_principal_fingerprint","createdAt":"2026-07-02T00:00:00Z","updatedAt":"2026-07-02T00:00:00Z","command":{"surface":"import","backendSelected":"imported-legacy","sourceBackendClass":"cas-lane"},"tuple":{"repoRealpath":"/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp"},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr_missing_fingerprint","reviewTurnId":"turn_missing_fingerprint"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","proofUsable":true,"reduced":false,"fallbackUsed":false}}
    , .{
        .session_id = "",
        .cwd = null,
        .command_surface = "receipt",
        .source_path = "/tmp/rer-missing-principal-fingerprint.json",
        .default_backend_class = "cas-receipt-normalized",
    });
    defer row.deinit();

    try std.testing.expectEqualStrings("review_untrusted_source", scalarString(row, "canonical_status").?);
    try std.testing.expect(!scalarBool(row, "tuple_verdict_exists"));
    try std.testing.expect(!scalarBool(row, "principal_proof_usable"));

    const summary = summarize(&.{row});
    try std.testing.expectEqual(@as(i64, 0), summary.completed_clean_count);

    var empty_row = try classifyReceiptText(std.testing.allocator,
        \\{"schema":"CAS-RER-v1","recordId":"rer_empty_principal_fingerprint","createdAt":"2026-07-02T00:00:00Z","updatedAt":"2026-07-02T00:00:00Z","command":{"surface":"import","backendSelected":"imported-legacy","sourceBackendClass":"cas-lane"},"tuple":{"repoRealpath":"/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp"},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr_empty_fingerprint","reviewTurnId":"turn_empty_fingerprint"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"","proofUsable":true,"reduced":false,"fallbackUsed":false}}
    , .{
        .session_id = "",
        .cwd = null,
        .command_surface = "receipt",
        .source_path = "/tmp/rer-empty-principal-fingerprint.json",
        .default_backend_class = "cas-receipt-normalized",
    });
    defer empty_row.deinit();

    try std.testing.expectEqualStrings("review_untrusted_source", scalarString(empty_row, "canonical_status").?);
    try std.testing.expect(!scalarBool(empty_row, "tuple_verdict_exists"));
    try std.testing.expect(!scalarBool(empty_row, "principal_proof_usable"));
}

test "CAS-RER unbound terminal status is not counted as completed evidence" {
    var row = try classifyReceiptText(std.testing.allocator,
        \\{"schema":"CAS-RER-v1","recordId":"rer_unbound_findings","createdAt":"2026-07-02T00:00:00Z","updatedAt":"2026-07-02T00:00:00Z","command":{"surface":"import","backendSelected":"imported-legacy","sourceBackendClass":"cas-lane"},"tuple":{"repoRealpath":"/repo","baseSha":"base","headSha":null,"targetFingerprint":"fp"},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr_unbound","reviewTurnId":"turn_unbound"},"verdict":{"tupleVerdictExists":false,"status":"findings","clean":false,"findingCount":1,"findings":[{"title":"unbound"}]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false}}
    , .{
        .session_id = "",
        .cwd = null,
        .command_surface = "receipt",
        .source_path = "/tmp/rer-unbound.json",
        .default_backend_class = "cas-receipt-normalized",
    });
    defer row.deinit();

    try std.testing.expectEqualStrings("incomplete", scalarString(row, "canonical_status").?);
    try std.testing.expectEqualStrings("incomplete", scalarString(row, "review_verdict_status").?);
    try std.testing.expect(!scalarBool(row, "tuple_verdict_exists"));
    try std.testing.expectEqual(@as(i64, 1), scalarInt(row, "finding_count"));

    const summary = summarize(&.{row});
    try std.testing.expectEqual(@as(i64, 0), summary.completed_clean_count);
    try std.testing.expectEqual(@as(i64, 0), summary.completed_findings_count);
}

test "CAS-RER findings are not reduced to timeout-only audit evidence" {
    var timeout_row = try classifyReceiptText(std.testing.allocator,
        \\{"reviewThreadId":"thr_same","reviewAttemptPhase":"review_waiting","timedOut":true,"baseSha":"base","headSha":"head","targetFingerprint":"fp"}
    , .{
        .session_id = "sess",
        .cwd = "/repo",
        .command_surface = "cas review_session lane review",
        .source_path = "/tmp/session.jsonl",
        .default_backend_class = "cas-lane",
    });
    defer timeout_row.deinit();

    var findings_row = try classifyReceiptText(std.testing.allocator,
        \\{"schema":"CAS-RER-v1","recordId":"rer_same","command":{"surface":"import","backendSelected":"imported-legacy","sourceBackendClass":"cas-lane"},"tuple":{"repoRealpath":"/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp"},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr_same","reviewTurnId":"turn_same"},"verdict":{"tupleVerdictExists":true,"status":"findings","clean":false,"findingCount":1,"findings":[{"title":"issue"}]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false}}
    , .{
        .session_id = "sess",
        .cwd = "/repo",
        .command_surface = "receipt",
        .source_path = "/tmp/rer.json",
        .default_backend_class = "cas-receipt-normalized",
    });
    defer findings_row.deinit();

    const summary = summarize(&.{ timeout_row, findings_row });
    try std.testing.expectEqual(@as(i64, 1), summary.completed_findings_count);
    try std.testing.expectEqual(@as(i64, 1), summary.timeout_with_handle_count);
    try std.testing.expectEqualStrings("cas_review_evidence_ledger", scalarString(findings_row, "canonical_source").?);
}

test "CAS import envelope expands nested CAS-RER records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(defaultIo(), .{ .sub_path = "import.json", .data =
        \\{"schema":"CAS-IMPORT-v1","records":[{"sourcePath":"/tmp/receipt.json","recordPath":"/tmp/rer.json","validation":{"ok":true,"errors":[],"path":"/tmp/receipt.json"},"record":{"schema":"CAS-RER-v1","recordId":"rer_envelope","command":{"surface":"import","backendSelected":"imported-legacy","sourceBackendClass":"cas-lane"},"tuple":{"repoRealpath":"/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp"},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr_env","reviewTurnId":"turn_env"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false}}},{"sourcePath":"/tmp/bad.json","recordPath":"","validation":{"ok":false,"errors":["bad"],"path":"/tmp/bad.json"},"record":{"schema":"CAS-RER-v1","recordId":"rer_rejected","command":{"surface":"import","backendSelected":"imported-legacy","sourceBackendClass":"cas-lane"},"tuple":{"repoRealpath":"/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp"},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr_bad","reviewTurnId":"turn_bad"},"verdict":{"tupleVerdictExists":true,"status":"findings","clean":false,"findingCount":1,"findings":[{"title":"bad"}]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false}}}],"errors":[]}
    });
    const root_abs = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const import_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "import.json" });
    defer std.testing.allocator.free(import_path);

    var audit = try compile(std.testing.allocator, .{
        .root = root_abs,
        .receipt_paths = &.{import_path},
    });
    defer audit.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), audit.rows.items.len);
    try std.testing.expectEqualStrings("rer_envelope", scalarString(audit.rows.items[0], "record_id").?);
    try std.testing.expectEqual(@as(i64, 1), audit.summary.completed_clean_count);
    try std.testing.expectEqual(@as(i64, 0), audit.summary.broker_run_count);
}

test "CAS import JSONL wrapper expands nested CAS-RER record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(defaultIo(), .{ .sub_path = "import.jsonl", .data =
        \\{"sourcePath":"/tmp/receipt.json","recordPath":"/tmp/rer.json","validation":{"ok":true,"errors":[],"path":"/tmp/receipt.json"},"record":{"schema":"CAS-RER-v1","recordId":"rer_jsonl_wrapper","command":{"surface":"import","backendSelected":"imported-legacy","sourceBackendClass":"cas-lane"},"tuple":{"repoRealpath":"/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp"},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr_jsonl","reviewTurnId":"turn_jsonl"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false}}}
    });
    const root_abs = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const import_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "import.jsonl" });
    defer std.testing.allocator.free(import_path);

    var audit = try compile(std.testing.allocator, .{
        .root = root_abs,
        .receipt_paths = &.{import_path},
    });
    defer audit.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), audit.rows.items.len);
    try std.testing.expectEqualStrings("rer_jsonl_wrapper", scalarString(audit.rows.items[0], "record_id").?);
    try std.testing.expectEqual(@as(i64, 1), audit.summary.completed_clean_count);
}

test "CAS run envelope expands nested CAS-RER record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(defaultIo(), .{ .sub_path = "run.json", .data =
        \\{"schema":"CAS-RUN-v1","recordPath":"/tmp/rer-run.json","record":{"schema":"CAS-RER-v1","recordId":"rer_run","command":{"surface":"run","backendSelected":"cas-run","sourceBackendClass":"cas-start-wait","brokerDecision":{"action":"replaced_dead_transport","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp"},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr_run","reviewTurnId":"turn_run"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false}},"reviewBrokerDecision":{"action":"replaced_dead_transport","reason":"test","freshAttemptRequired":false}}
    });
    const root_abs = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const run_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "run.json" });
    defer std.testing.allocator.free(run_path);

    var audit = try compile(std.testing.allocator, .{
        .root = root_abs,
        .receipt_paths = &.{run_path},
    });
    defer audit.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), audit.rows.items.len);
    try std.testing.expectEqualStrings("rer_run", scalarString(audit.rows.items[0], "record_id").?);
    try std.testing.expectEqualStrings("cas_review_evidence_ledger", scalarString(audit.rows.items[0], "canonical_source").?);
    try std.testing.expectEqual(@as(i64, 1), audit.summary.completed_clean_count);
    try std.testing.expectEqual(@as(i64, 1), audit.summary.broker_run_count);
    try std.testing.expectEqual(@as(i64, 1), audit.summary.broker_auto_replaced_dead_transport_count);
}

test "repo scope matching is path-boundary safe" {
    try std.testing.expect(pathMatchesScope("/tmp/repo", "/tmp/repo"));
    try std.testing.expect(pathMatchesScope("/tmp/repo/sub", "/tmp/repo"));
    try std.testing.expect(!pathMatchesScope("/tmp/repo-old", "/tmp/repo"));
}

test "summary separates review transport timeout duplicate and degraded lane tuple verdict" {
    var transport_row = try classifyReceiptText(std.testing.allocator,
        \\{"reviewThreadId":"thr_transport","failureCode":"lane_transport_lost","reviewAttemptPhase":"review_terminal","baseSha":"b","headSha":"h","targetFingerprint":"t"}
    , .{
        .session_id = "sess",
        .cwd = "/repo",
        .command_surface = "cas review_session lane review",
        .source_path = "/tmp/session.jsonl",
        .default_backend_class = "cas-lane",
    });
    defer transport_row.deinit();

    var waiting_row = try classifyReceiptText(std.testing.allocator,
        \\{"reviewThreadId":"thr_waiting","reviewAttemptPhase":"review_waiting","timedOut":true,"baseSha":"b","headSha":"h","targetFingerprint":"t"}
    , .{
        .session_id = "sess",
        .cwd = "/repo",
        .command_surface = "cas review_session lane review",
        .source_path = "/tmp/session.jsonl",
        .default_backend_class = "cas-lane",
    });
    defer waiting_row.deinit();

    var tuple_row = try classifyReceiptText(std.testing.allocator,
        \\{"reviewThreadId":"thr_clean","baseSha":"b","headSha":"h","targetFingerprint":"t","reviewVerdict":{"status":"clean","clean":true,"findingCount":0,"failureCode":null,"baseSha":"b","headSha":"h","targetFingerprint":"t","reviewThreadId":"thr_clean","backendClass":"cas-lane"}}
    , .{
        .session_id = "sess",
        .cwd = "/repo",
        .command_surface = "cas review_session lane review",
        .source_path = "/tmp/session.jsonl",
        .default_backend_class = "cas-lane",
    });
    defer tuple_row.deinit();

    const summary = summarize(&.{ transport_row, waiting_row, tuple_row });
    try std.testing.expectEqual(@as(i64, 1), summary.review_attempt_transport_failure_count);
    try std.testing.expectEqual(@as(i64, 1), summary.timeout_with_handle_count);
    try std.testing.expectEqual(@as(i64, 0), summary.duplicate_prevented_count);
    try std.testing.expectEqualStrings("degraded", summary.lane_backend_status);
}
