const std = @import("std");
const query = @import("query/engine.zig");
const spec = @import("types/spec.zig");
const time_utils = @import("time_utils.zig");

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const projection_fields = [_][]const u8{
    "session_id",
    "cwd",
    "command_surface",
    "backend_class",
    "review_attempt_phase",
    "review_attempt_exists",
    "proof_verdict_exists",
    "failure_code",
    "failure_class",
    "retryable_same_tuple_now",
    "lane_id",
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
    lane_backend_status: []const u8 = "unproven",
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
            try pending.put(call_id, .{
                .call_id = call_id,
                .session_id = session_id,
                .timestamp = ts,
                .command = cmd,
                .cwd = stringField(args_obj, "workdir"),
            });
            continue;
        }

        if (std.mem.eql(u8, payload_type, "exec_command_end")) {
            const call_id = stringField(payload, "call_id") orelse continue;
            const call = pending.get(call_id) orelse continue;
            const stdout = stringField(payload, "stdout") orelse stringField(payload, "output") orelse "";
            const stderr = stringField(payload, "stderr") orelse "";
            try appendRowsFromCommandText(allocator, stdout, stderr, call, path, params, audit, dedupe);
        }
    }
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
    const slash = std.mem.lastIndexOfScalar(u8, glob, '/') orelse return;
    const dir_path = if (slash == 0) "/" else glob[0..slash];
    const pattern = glob[slash + 1 ..];
    var dir = std.Io.Dir.openDirAbsolute(defaultIo(), dir_path, .{ .iterate = true }) catch return;
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
        var row = classifyReceiptText(allocator, json_text, .{
            .session_id = call.session_id,
            .cwd = call.cwd,
            .command_surface = call.command,
            .source_path = session_path,
            .default_backend_class = backendFromCommand(call.command),
        }) catch continue;
        errdefer row.deinit();
        if (!rowMatchesFilters(row, params)) {
            row.deinit();
            continue;
        }
        if (try claimDedupeKey(allocator, row, session_path, call.call_id, dedupe)) {
            try audit.rows.append(allocator, row);
        } else {
            row.deinit();
        }
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
    while (findJsonObject(text, &cursor)) |json_text| {
        found = true;
        var row = classifyReceiptText(allocator, json_text, .{
            .session_id = "",
            .cwd = null,
            .command_surface = "receipt",
            .source_path = path,
            .default_backend_class = "cas-receipt-normalized",
        }) catch continue;
        errdefer row.deinit();
        if (!rowMatchesFilters(row, params)) {
            row.deinit();
            continue;
        }
        if (try claimDedupeKey(allocator, row, path, "", dedupe)) {
            try audit.rows.append(allocator, row);
        } else {
            row.deinit();
        }
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

fn classifyReceiptText(allocator: std.mem.Allocator, text: []const u8, ctx: ClassifyContext) !query.Row {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const root = object(parsed.value) orelse return error.InvalidReceipt;
    return classifyReceiptObject(allocator, root, ctx);
}

fn classifyReceiptObject(allocator: std.mem.Allocator, root: std.json.ObjectMap, ctx: ClassifyContext) !query.Row {
    const verdict = objectField(root, "reviewVerdict");
    const failure_code_raw = stringField(root, "failureCode");
    const review_thread_id = nullableString(root, "reviewThreadId") orelse if (verdict) |v| nullableString(v, "reviewThreadId") else null;
    const review_turn_id = nullableString(root, "reviewTurnId") orelse if (verdict) |v| nullableString(v, "reviewTurnId") else null;
    const base_sha = nullableString(root, "baseSha") orelse if (verdict) |v| nullableString(v, "baseSha") else null;
    const head_sha = nullableString(root, "headSha") orelse if (verdict) |v| nullableString(v, "headSha") else null;
    const target_fingerprint = nullableString(root, "targetFingerprint") orelse if (verdict) |v| nullableString(v, "targetFingerprint") else null;
    const review_count = intField(root, "reviewCount") orelse 0;
    const last_review_thread_id = nullableString(root, "lastReviewThreadId");
    const last_head_sha = nullableString(root, "lastHeadSha");
    const verdict_status = if (verdict) |v| nullableString(v, "status") else null;

    const legacy_pre_review_transport =
        optEql(failure_code_raw, "lane_transport_lost") and
        review_count == 0 and
        last_review_thread_id == null and
        last_head_sha == null and
        review_thread_id == null and
        verdict == null;

    const failure_code = if (legacy_pre_review_transport) "pre_review_lane_transport_lost" else failure_code_raw;
    const phase = stringField(root, "reviewAttemptPhase") orelse inferPhase(root, verdict, review_thread_id, failure_code, legacy_pre_review_transport);
    const review_attempt_exists = boolField(root, "reviewAttemptExists") orelse (review_thread_id != null);
    const proof_verdict_exists = boolField(root, "proofVerdictExists") orelse tupleBoundVerdict(verdict, base_sha, head_sha, target_fingerprint);
    const backend_class = if (verdict) |v| nullableString(v, "backendClass") orelse ctx.default_backend_class else ctx.default_backend_class;
    const record_path = nullableString(root, "recordPath") orelse if (verdict) |v| nullableString(v, "recordPath") else null;
    const event_log_path = nullableString(root, "eventLogPath") orelse if (verdict) |v| nullableString(v, "eventLogPath") else null;
    const finding_count = if (verdict) |v| intField(v, "findingCount") orelse 0 else intField(root, "findingCount") orelse 0;

    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putStringOrNull(&row, "session_id", nonEmpty(ctx.session_id));
    try putStringOrNull(&row, "cwd", nullableString(root, "cwd") orelse ctx.cwd);
    try row.putStaticKey("command_surface", .{ .string = ctx.command_surface });
    try row.putStaticKey("backend_class", .{ .string = backend_class });
    try row.putStaticKey("review_attempt_phase", .{ .string = phase });
    try row.putStaticKey("review_attempt_exists", .{ .bool = review_attempt_exists });
    try row.putStaticKey("proof_verdict_exists", .{ .bool = proof_verdict_exists });
    try putStringOrNull(&row, "failure_code", failure_code);
    try putStringOrNull(&row, "failure_class", nullableString(root, "failureClass"));
    try putBoolOrNull(&row, "retryable_same_tuple_now", boolField(root, "retryableSameTupleNow"));
    try putStringOrNull(&row, "lane_id", nullableString(root, "laneId"));
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
    try row.putStaticKey("transport_signal", .{ .bool = transportSignal(failure_code, nullableString(root, "failureClass")) });
    try putStringOrNull(&row, "record_path", record_path);
    try putStringOrNull(&row, "event_log_path", event_log_path);
    return row;
}

fn summarize(rows: []const query.Row) Summary {
    var out = Summary{ .row_count = @intCast(rows.len) };
    var has_proof = false;
    var has_lane_proof = false;
    var has_pre_review_failure = false;
    var has_degraded = false;

    for (rows) |row| {
        const failure_code = scalarString(row, "failure_code");
        const phase = scalarString(row, "review_attempt_phase");
        const status = scalarString(row, "review_verdict_status");
        const backend = scalarString(row, "backend_class");
        const attempt_exists = scalarBool(row, "review_attempt_exists");
        const proof_exists = scalarBool(row, "proof_verdict_exists");
        const finding_count = scalarInt(row, "finding_count");

        if (optEql(failure_code, "pre_review_lane_transport_lost")) {
            out.pre_review_lane_transport_lost_count += 1;
            has_pre_review_failure = true;
        }
        if (optEql(failure_code, "review_transport_lost") or (optEql(scalarString(row, "failure_class"), "transport") and attempt_exists)) {
            out.review_attempt_transport_failure_count += 1;
            has_degraded = true;
        }
        if (optEql(status, "findings")) out.completed_findings_count += 1;
        if (optEql(status, "clean")) out.completed_clean_count += 1;
        if (optEql(status, "account_resource_exhausted") or optEql(failure_code, "account_resource_exhausted") or scalarBool(row, "account_resource_signal")) {
            out.account_resource_exhausted_count += 1;
            has_degraded = true;
        }
        if (optEql(status, "timeout") and attempt_exists) out.timeout_with_handle_count += 1;
        if (optEql(failure_code, "duplicate_prevented") or optEql(phase, "review_waiting")) out.duplicate_prevented_count += 1;
        if (std.mem.indexOf(u8, backend orelse "", "cas-start-wait") != null or std.mem.indexOf(u8, backend orelse "", "cas-native-fallback") != null) {
            if (proof_exists) out.start_wait_normalized_count += 1 else out.start_wait_unormalized_count += 1;
            has_degraded = true;
        }
        if (proof_exists and (optEql(status, "clean") or optEql(status, "findings"))) {
            has_proof = true;
            if (optEql(backend, "cas-lane")) has_lane_proof = true;
            if (finding_count > 0) out.completed_findings_count += 0;
        }
    }

    out.lane_backend_status = if (has_lane_proof and !has_pre_review_failure)
        "proven"
    else if (has_pre_review_failure and !has_proof)
        "failing_pre_review"
    else if (has_proof or has_degraded or has_pre_review_failure)
        "degraded"
    else
        "unproven";
    return out;
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

fn tupleBoundVerdict(verdict: ?std.json.ObjectMap, base: ?[]const u8, head: ?[]const u8, fingerprint: ?[]const u8) bool {
    const v = verdict orelse return false;
    return base != null and head != null and fingerprint != null and
        optEql(nullableString(v, "baseSha"), base.?) and
        optEql(nullableString(v, "headSha"), head.?) and
        optEql(nullableString(v, "targetFingerprint"), fingerprint.?);
}

fn accountResourceSignal(root: std.json.ObjectMap, verdict: ?std.json.ObjectMap) bool {
    if (optEql(nullableString(root, "failureCode"), "account_resource_exhausted")) return true;
    if (verdict) |v| {
        if (optEql(nullableString(v, "status"), "account_resource_exhausted")) return true;
        if (optEql(nullableString(v, "failureCode"), "account_resource_exhausted")) return true;
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
    if (optEql(failure_class, "transport")) return true;
    const code = failure_code orelse return false;
    return std.mem.indexOf(u8, code, "transport") != null or std.mem.indexOf(u8, code, "lane_transport") != null;
}

fn rowMatchesFilters(row: query.Row, params: Params) bool {
    if (params.session_id) |want| {
        if (!optEql(scalarString(row, "session_id"), want)) return false;
    }
    if (params.repo) |want| {
        const cwd = scalarString(row, "cwd") orelse "";
        if (!std.mem.startsWith(u8, cwd, want)) return false;
    }
    if (params.workdir) |want| {
        const cwd = scalarString(row, "cwd") orelse "";
        if (!std.mem.startsWith(u8, cwd, want)) return false;
    }
    if (params.base_sha) |want| if (!optEql(scalarString(row, "base_sha"), want)) return false;
    if (params.head_sha) |want| if (!optEql(scalarString(row, "head_sha"), want)) return false;
    if (params.target_fingerprint) |want| if (!optEql(scalarString(row, "target_fingerprint"), want)) return false;
    if (params.exclude_current_session_id) |current| {
        if (optEql(scalarString(row, "session_id"), current)) return false;
    }
    return true;
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
    return std.mem.indexOf(u8, cmd, "cas review_session") != null or
        std.mem.indexOf(u8, cmd, "cas_review_session") != null or
        std.mem.indexOf(u8, cmd, "review_session") != null;
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

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |v| v,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |v| v,
        else => null,
    };
}

fn putStringOrNull(row: *query.Row, key: []const u8, value: ?[]const u8) !void {
    if (value) |text| try row.putStaticKey(key, .{ .string = text }) else try row.putStaticKey(key, .null);
}

fn putBoolOrNull(row: *query.Row, key: []const u8, value: ?bool) !void {
    if (value) |v| try row.putStaticKey(key, .{ .bool = v }) else try row.putStaticKey(key, .null);
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

test "tuple-bound review verdict proves normalized verdict" {
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
    try std.testing.expect(scalarBool(row, "proof_verdict_exists"));

    const summary = summarize(&.{row});
    try std.testing.expectEqual(@as(i64, 1), summary.completed_clean_count);
    try std.testing.expectEqualStrings("degraded", summary.lane_backend_status);
}
