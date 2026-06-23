const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;

pub const AttemptResult = enum {
    pass,
    gate_fail,
    usage_error,
    system_error,
    unknown,
};

pub const GcrState = enum {
    current,
    stale,
    absent,
    failed,
    unknown,
    execution_denied,
    blocking_debt,
};

pub const GcrAttempt = struct {
    call_id: ?[]u8,
    timestamp: ?[]u8,
    exit_code: ?i64,
    result: AttemptResult,
    gcr_id: ?[]u8,
    diagnostic_refs: [][]u8,

    pub fn deinit(self: *GcrAttempt, allocator: std.mem.Allocator) void {
        freeOpt(allocator, self.call_id);
        freeOpt(allocator, self.timestamp);
        freeOpt(allocator, self.gcr_id);
        freeStringList(allocator, self.diagnostic_refs);
    }
};

pub const GcrEvidence = struct {
    gcr_id: []u8,
    source_ref: []u8,
    timestamp: ?[]u8,
    plan_seq: ?[]u8,
    structure_fingerprint: ?[]u8,
    contract_fingerprint: ?[]u8,
    coverage_fingerprint: ?[]u8,
    execution_fingerprint: ?[]u8,
    execution_allowed: bool,
    blocking_debt: [][]u8,
    selected_task_ids: [][]u8,
    projection_fingerprint: ?[]u8,
    current_until_event: ?[]u8,

    pub fn deinit(self: *GcrEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.gcr_id);
        allocator.free(self.source_ref);
        freeOpt(allocator, self.timestamp);
        freeOpt(allocator, self.plan_seq);
        freeOpt(allocator, self.structure_fingerprint);
        freeOpt(allocator, self.contract_fingerprint);
        freeOpt(allocator, self.coverage_fingerprint);
        freeOpt(allocator, self.execution_fingerprint);
        freeStringList(allocator, self.blocking_debt);
        freeStringList(allocator, self.selected_task_ids);
        freeOpt(allocator, self.projection_fingerprint);
        freeOpt(allocator, self.current_until_event);
    }
};

pub const GraphControlViolation = struct {
    violation_id: []u8,
    mutation_event_ref: []u8,
    gcr_state: GcrState,
    last_gcr_ref: ?[]u8,
    diagnostic_refs: [][]u8,
    severity: []u8,

    pub fn deinit(self: *GraphControlViolation, allocator: std.mem.Allocator) void {
        allocator.free(self.violation_id);
        allocator.free(self.mutation_event_ref);
        freeOpt(allocator, self.last_gcr_ref);
        freeStringList(allocator, self.diagnostic_refs);
        allocator.free(self.severity);
    }
};

pub const ProjectionInversion = struct {
    present: bool = false,
    first_event: ?[]u8 = null,
    update_plan_count: usize = 0,
    patch_count: usize = 0,
    last_valid_gcr: ?[]u8 = null,
    evidence_refs: [][]u8 = &.{},

    pub fn deinit(self: *ProjectionInversion, allocator: std.mem.Allocator) void {
        freeOpt(allocator, self.first_event);
        freeOpt(allocator, self.last_valid_gcr);
        freeStringList(allocator, self.evidence_refs);
    }
};

pub const ProjectionMetrics = struct {
    update_plan_calls: usize = 0,
    distinct_gcrs: usize = 0,
    unbound_update_plan_calls: usize = 0,
    hand_authored_projection_calls: usize = 0,
    projection_drift_repairs: usize = 0,
    projection_inversion: ProjectionInversion = .{},

    pub fn deinit(self: *ProjectionMetrics, allocator: std.mem.Allocator) void {
        self.projection_inversion.deinit(allocator);
    }
};

pub const Analysis = struct {
    compile_attempts: []GcrAttempt,
    gcrs: []GcrEvidence,
    control_violations: []GraphControlViolation,
    projection: ProjectionMetrics,
    material_mutations: usize,
    material_mutations_without_current_executable_gcr: usize,
    current_gcr_at_end: ?[]u8,
    gcr_state_at_end: GcrState,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        for (self.compile_attempts) |*item| item.deinit(allocator);
        allocator.free(self.compile_attempts);
        for (self.gcrs) |*item| item.deinit(allocator);
        allocator.free(self.gcrs);
        for (self.control_violations) |*item| item.deinit(allocator);
        allocator.free(self.control_violations);
        self.projection.deinit(allocator);
        freeOpt(allocator, self.current_gcr_at_end);
    }
};

const ScanState = struct {
    gcr_state: GcrState = .absent,
    current_gcr_id: ?[]const u8 = null,
    latest_gcr_id: ?[]const u8 = null,
    latest_attempt_result: ?AttemptResult = null,
    noncurrent_update_plan_calls: usize = 0,
    noncurrent_patches: usize = 0,
    material_graph_context: bool = false,
};

pub fn analyzeTrace(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace) !Analysis {
    var attempts: std.ArrayList(GcrAttempt) = .empty;
    errdefer deinitAttemptList(allocator, attempts.items);
    var gcrs: std.ArrayList(GcrEvidence) = .empty;
    errdefer deinitGcrList(allocator, gcrs.items);
    var violations: std.ArrayList(GraphControlViolation) = .empty;
    errdefer deinitViolationList(allocator, violations.items);
    var projection = ProjectionMetrics{};
    errdefer projection.deinit(allocator);

    var scan = ScanState{};
    var material_mutations: usize = 0;

    for (trace.tools.items, 0..) |tool, index| {
        const event_ref = try eventRef(allocator, tool, index);
        defer allocator.free(event_ref);

        if (isCompileAttempt(tool)) {
            scan.material_graph_context = true;
            const parsed_gcr = try parseGcrEvidence(allocator, tool, event_ref);
            const result = classifyAttempt(tool, parsed_gcr);
            const gcr_id = if (parsed_gcr) |evidence| try allocator.dupe(u8, evidence.gcr_id) else null;
            try attempts.append(allocator, .{
                .call_id = try dupOpt(allocator, tool.call_id),
                .timestamp = try dupOpt(allocator, tool.started_at orelse tool.completed_at),
                .exit_code = tool.exit_code,
                .result = result,
                .gcr_id = gcr_id,
                .diagnostic_refs = try diagnosticRefsForAttempt(allocator, result, event_ref),
            });
            scan.latest_attempt_result = result;
            if (parsed_gcr) |evidence| {
                try gcrs.append(allocator, evidence);
                scan.current_gcr_id = gcrs.items[gcrs.items.len - 1].gcr_id;
                scan.latest_gcr_id = scan.current_gcr_id;
                if (evidence.execution_allowed and evidence.blocking_debt.len == 0) {
                    scan.gcr_state = .current;
                } else if (!evidence.execution_allowed) {
                    scan.gcr_state = .execution_denied;
                } else {
                    scan.gcr_state = .blocking_debt;
                }
                scan.noncurrent_update_plan_calls = 0;
                scan.noncurrent_patches = 0;
            } else if (result == .pass) {
                scan.gcr_state = .unknown;
                scan.current_gcr_id = null;
            } else {
                scan.gcr_state = .failed;
                scan.current_gcr_id = null;
            }
            continue;
        }

        if (isGraphInvalidator(tool) and scan.gcr_state == .current) {
            scan.gcr_state = .stale;
            scan.current_gcr_id = null;
        }

        if (isUpdatePlan(tool)) {
            projection.update_plan_calls += 1;
            if (scan.gcr_state == .current and scan.current_gcr_id != null) {
                projection.distinct_gcrs = gcrs.items.len;
            } else {
                projection.unbound_update_plan_calls += 1;
                projection.hand_authored_projection_calls += 1;
                scan.noncurrent_update_plan_calls += 1;
            }
        }

        if (isMaterialMutation(tool)) {
            material_mutations += 1;
            if (scan.gcr_state != .current) {
                try violations.append(allocator, try buildViolation(
                    allocator,
                    violations.items.len,
                    event_ref,
                    scan.gcr_state,
                    scan.latest_gcr_id,
                ));
                scan.noncurrent_patches += 1;
            }
            if (scan.material_graph_context and scan.gcr_state != .current and scan.noncurrent_update_plan_calls >= 2) {
                try markProjectionInversion(allocator, &projection.projection_inversion, event_ref, scan.noncurrent_update_plan_calls, scan.noncurrent_patches, scan.latest_gcr_id);
            }
        }
    }

    const violation_count = violations.items.len;
    return .{
        .compile_attempts = try attempts.toOwnedSlice(allocator),
        .gcrs = try gcrs.toOwnedSlice(allocator),
        .control_violations = try violations.toOwnedSlice(allocator),
        .projection = projection,
        .material_mutations = material_mutations,
        .material_mutations_without_current_executable_gcr = violation_count,
        .current_gcr_at_end = if (scan.gcr_state == .current and scan.current_gcr_id != null) try allocator.dupe(u8, scan.current_gcr_id.?) else null,
        .gcr_state_at_end = scan.gcr_state,
    };
}

fn parseGcrEvidence(allocator: std.mem.Allocator, tool: canonical_trace.ToolLifecycleRecord, source_ref: []const u8) !?GcrEvidence {
    const text = tool.output_text orelse return null;
    if (!contains(text, "graph_control_receipt") and !contains(text, "GCR-v1") and !contains(text, "GCR-")) return null;
    const gcr_id = try extractFirstOwned(allocator, text, &.{
        "\"receipt_id\":\"",
        "\"gcr_id\":\"",
        "receipt_id: ",
        "gcr_id: ",
        "GCR-",
    }, true) orelse return null;
    errdefer allocator.free(gcr_id);
    const blocking_debt = try extractStringList(allocator, text, "blocking_debt");
    errdefer freeStringList(allocator, blocking_debt);
    const selected = try extractStringList(allocator, text, "selected_task_ids");
    errdefer freeStringList(allocator, selected);
    const execution_allowed = !containsJsonBoolFalse(text, "execution_allowed") and
        !contains(text, "execution_allowed: false") and
        !contains(text, "execution_allowed=no");

    return .{
        .gcr_id = gcr_id,
        .source_ref = try allocator.dupe(u8, source_ref),
        .timestamp = try dupOpt(allocator, tool.started_at orelse tool.completed_at),
        .plan_seq = try extractFirstOwned(allocator, text, &.{ "\"plan_seq\":", "plan_seq: " }, false),
        .structure_fingerprint = try extractFirstOwned(allocator, text, &.{ "\"structure_fingerprint\":\"", "structure_fingerprint: " }, false),
        .contract_fingerprint = try extractFirstOwned(allocator, text, &.{ "\"contract_fingerprint\":\"", "contract_fingerprint: " }, false),
        .coverage_fingerprint = try extractFirstOwned(allocator, text, &.{ "\"coverage_fingerprint\":\"", "coverage_fingerprint: " }, false),
        .execution_fingerprint = try extractFirstOwned(allocator, text, &.{ "\"execution_fingerprint\":\"", "execution_fingerprint: " }, false),
        .execution_allowed = execution_allowed,
        .blocking_debt = blocking_debt,
        .selected_task_ids = selected,
        .projection_fingerprint = try extractFirstOwned(allocator, text, &.{ "\"projection_fingerprint\":\"", "projection_fingerprint: " }, false),
        .current_until_event = null,
    };
}

fn classifyAttempt(tool: canonical_trace.ToolLifecycleRecord, gcr: ?GcrEvidence) AttemptResult {
    const text = joinedToolText(tool);
    if (gcr) |evidence| {
        if (tool.exit_code != null and tool.exit_code.? != 0) return .system_error;
        if (!evidence.execution_allowed or evidence.blocking_debt.len > 0) return .gate_fail;
        return .pass;
    }
    if (contains(text, "usage") or contains(text, "unknown option") or contains(text, "invalid argument")) return .usage_error;
    if (tool.exit_code) |code| {
        if (code != 0) return .system_error;
    }
    return .unknown;
}

fn isCompileAttempt(tool: canonical_trace.ToolLifecycleRecord) bool {
    return toolContains(tool, "st compile aperture");
}

fn isUpdatePlan(tool: canonical_trace.ToolLifecycleRecord) bool {
    return toolContains(tool, "update_plan");
}

fn isMaterialMutation(tool: canonical_trace.ToolLifecycleRecord) bool {
    if (tool.patch_success == false) return false;
    if (tool.kind == .patch_apply) return true;
    if (tool.patch_changes_json != null) return true;
    if (tool.tool_name) |name| if (contains(name, "apply_patch")) return true;
    return toolContains(tool, "*** Begin Patch");
}

fn containsJsonBoolFalse(text: []const u8, key: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, key)) |idx| {
        var pos = idx + key.len;
        while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
        if (pos >= text.len or text[pos] != '"') {
            start = idx + key.len;
            continue;
        }
        pos += 1;
        while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
        if (pos >= text.len or text[pos] != ':') {
            start = idx + key.len;
            continue;
        }
        pos += 1;
        while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
        if (std.mem.startsWith(u8, text[pos..], "false")) return true;
        start = idx + key.len;
    }
    return false;
}

fn isGraphInvalidator(tool: canonical_trace.ToolLifecycleRecord) bool {
    const command = tool.command_text orelse tool.input_text orelse "";
    if (!contains(command, "st ")) return false;
    return contains(command, "st complete") or
        contains(command, "st intake apply") or
        contains(command, "st set") or
        contains(command, "st proof record") or
        contains(command, "st waive") or
        contains(command, "st graph debt") or
        contains(command, "st compile aperture");
}

fn buildViolation(
    allocator: std.mem.Allocator,
    index: usize,
    mutation_event_ref: []const u8,
    gcr_state: GcrState,
    latest_gcr_id: ?[]const u8,
) !GraphControlViolation {
    var refs: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, refs.items);
    try refs.append(allocator, try allocator.dupe(u8, "material mutation did not have current executable GCR"));
    return .{
        .violation_id = try std.fmt.allocPrint(allocator, "gcv-{d}", .{index + 1}),
        .mutation_event_ref = try allocator.dupe(u8, mutation_event_ref),
        .gcr_state = gcr_state,
        .last_gcr_ref = try dupOpt(allocator, latest_gcr_id),
        .diagnostic_refs = try refs.toOwnedSlice(allocator),
        .severity = try allocator.dupe(u8, "high"),
    };
}

fn markProjectionInversion(
    allocator: std.mem.Allocator,
    inversion: *ProjectionInversion,
    event_ref_value: []const u8,
    update_plan_count: usize,
    patch_count: usize,
    latest_gcr_id: ?[]const u8,
) !void {
    if (!inversion.present) {
        inversion.present = true;
        inversion.first_event = try allocator.dupe(u8, event_ref_value);
        inversion.last_valid_gcr = try dupOpt(allocator, latest_gcr_id);
        var refs: std.ArrayList([]u8) = .empty;
        errdefer freeStringList(allocator, refs.items);
        try refs.append(allocator, try allocator.dupe(u8, event_ref_value));
        inversion.evidence_refs = try refs.toOwnedSlice(allocator);
    }
    inversion.update_plan_count = update_plan_count;
    inversion.patch_count = patch_count;
}

fn diagnosticRefsForAttempt(allocator: std.mem.Allocator, result: AttemptResult, event_ref_value: []const u8) ![][]u8 {
    var refs: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, refs.items);
    if (result != .pass) try refs.append(allocator, try allocator.dupe(u8, event_ref_value));
    return refs.toOwnedSlice(allocator);
}

fn eventRef(allocator: std.mem.Allocator, tool: canonical_trace.ToolLifecycleRecord, fallback_index: usize) ![]u8 {
    if (tool.call_id) |call_id| return std.fmt.allocPrint(allocator, "tool:{s}", .{call_id});
    if (tool.turn_index) |turn_index| return std.fmt.allocPrint(allocator, "turn:{d}:tool:{d}", .{ turn_index, fallback_index });
    return std.fmt.allocPrint(allocator, "tool:{d}", .{fallback_index});
}

fn extractFirstOwned(
    allocator: std.mem.Allocator,
    text: []const u8,
    prefixes: []const []const u8,
    include_gcr_prefix: bool,
) !?[]u8 {
    for (prefixes) |prefix| {
        if (std.mem.indexOf(u8, text, prefix)) |idx| {
            const start = idx + prefix.len;
            var end = start;
            while (end < text.len and isTokenChar(text[end])) : (end += 1) {}
            if (include_gcr_prefix and std.mem.eql(u8, prefix, "GCR-")) {
                return try std.fmt.allocPrint(allocator, "GCR-{s}", .{text[start..end]});
            }
            if (end > start) return try allocator.dupe(u8, text[start..end]);
        }
    }
    return null;
}

fn extractStringList(allocator: std.mem.Allocator, text: []const u8, field: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    const field_index = std.mem.indexOf(u8, text, field) orelse return out.toOwnedSlice(allocator);
    const rest = text[field_index..];
    const open_rel = std.mem.indexOfScalar(u8, rest, '[') orelse return out.toOwnedSlice(allocator);
    const after_open = rest[open_rel + 1 ..];
    const close_rel = std.mem.indexOfScalar(u8, after_open, ']') orelse return out.toOwnedSlice(allocator);
    const inner = after_open[0..close_rel];
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, inner, cursor, '"')) |quote_start| {
        const value_start = quote_start + 1;
        const quote_end = std.mem.indexOfScalarPos(u8, inner, value_start, '"') orelse break;
        if (quote_end > value_start) try out.append(allocator, try allocator.dupe(u8, inner[value_start..quote_end]));
        cursor = quote_end + 1;
    }
    return out.toOwnedSlice(allocator);
}

fn isTokenChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ':' or byte == '.';
}

fn toolContains(tool: canonical_trace.ToolLifecycleRecord, needle: []const u8) bool {
    if (tool.tool_name) |text| if (contains(text, needle)) return true;
    if (tool.command_text) |text| if (contains(text, needle)) return true;
    if (tool.input_text) |text| if (contains(text, needle)) return true;
    if (tool.output_text) |text| if (contains(text, needle)) return true;
    if (tool.arguments_json) |text| if (contains(text, needle)) return true;
    return false;
}

fn joinedToolText(tool: canonical_trace.ToolLifecycleRecord) []const u8 {
    if (tool.output_text) |text| return text;
    if (tool.command_text) |text| return text;
    if (tool.input_text) |text| return text;
    if (tool.arguments_json) |text| return text;
    return "";
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn dupOpt(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    if (value) |v| return try allocator.dupe(u8, v);
    return null;
}

fn freeOpt(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |v| allocator.free(v);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn deinitAttemptList(allocator: std.mem.Allocator, values: []GcrAttempt) void {
    for (values) |*value| value.deinit(allocator);
}

fn deinitGcrList(allocator: std.mem.Allocator, values: []GcrEvidence) void {
    for (values) |*value| value.deinit(allocator);
}

fn deinitViolationList(allocator: std.mem.Allocator, values: []GraphControlViolation) void {
    for (values) |*value| value.deinit(allocator);
}

test "gcr analyzer accepts current receipt before material mutation" {
    var trace = try fixtureTrace(std.testing.allocator);
    defer trace.deinit(std.testing.allocator);
    try appendTool(std.testing.allocator, &trace, .exec_command, "compile", "st compile aperture --file .step/st-plan.jsonl", "graph_control_receipt {\"receipt_id\":\"GCR-1\",\"plan_seq\":1,\"execution_allowed\":true,\"selected_task_ids\":[\"st-aa-003\"]}", 0);
    try appendTool(std.testing.allocator, &trace, .patch_apply, "apply_patch", null, null, null);

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.compile_attempts.len);
    try std.testing.expectEqual(AttemptResult.pass, analysis.compile_attempts[0].result);
    try std.testing.expectEqual(@as(usize, 1), analysis.gcrs.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.control_violations.len);
    try std.testing.expectEqual(GcrState.current, analysis.gcr_state_at_end);
}

test "gcr analyzer detects failed compile projection inversion before patch" {
    var trace = try fixtureTrace(std.testing.allocator);
    defer trace.deinit(std.testing.allocator);
    try appendTool(std.testing.allocator, &trace, .exec_command, "compile", "st compile aperture --file .step/st-plan.jsonl", "error: blocking debt", 1);
    try appendTool(std.testing.allocator, &trace, .mcp_tool, "update_plan", "update_plan selected st-aa-003", null, null);
    try appendTool(std.testing.allocator, &trace, .mcp_tool, "update_plan", "update_plan selected st-aa-003", null, null);
    try appendTool(std.testing.allocator, &trace, .patch_apply, "apply_patch", null, null, null);

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(AttemptResult.system_error, analysis.compile_attempts[0].result);
    try std.testing.expectEqual(@as(usize, 1), analysis.control_violations.len);
    try std.testing.expect(analysis.projection.projection_inversion.present);
    try std.testing.expectEqual(@as(usize, 2), analysis.projection.projection_inversion.update_plan_count);
}

fn fixtureTrace(allocator: std.mem.Allocator) !canonical_trace.CanonicalSessionTrace {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(allocator, "/tmp/run.jsonl"),
    };
    errdefer trace.deinit(allocator);
    trace.session.session_id = try allocator.dupe(u8, "session-1");
    return trace;
}

fn appendTool(
    allocator: std.mem.Allocator,
    trace: *canonical_trace.CanonicalSessionTrace,
    kind: canonical_trace.ToolKind,
    tool_name: []const u8,
    command: ?[]const u8,
    output_text: ?[]const u8,
    exit_code: ?i64,
) !void {
    const idx = trace.tools.items.len + 1;
    try trace.tools.append(allocator, .{
        .path = try allocator.dupe(u8, "/tmp/run.jsonl"),
        .turn_index = 1,
        .call_id = try std.fmt.allocPrint(allocator, "call-{d}", .{idx}),
        .kind = kind,
        .tool_name = try allocator.dupe(u8, tool_name),
        .command_text = if (command) |text| try allocator.dupe(u8, text) else null,
        .input_text = if (command == null) try allocator.dupe(u8, tool_name) else null,
        .output_text = if (output_text) |text| try allocator.dupe(u8, text) else null,
        .exit_code = exit_code,
    });
}
