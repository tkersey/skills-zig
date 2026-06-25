const std = @import("std");
const query = @import("query/engine.zig");
const spec = @import("types/spec.zig");
const output = @import("output/mod.zig");

pub const audit_version = "STWA-v1";
pub const scanner_version = "stwa-scanner-v1";

pub const dataset_names = [_][]const u8{
    "st_workspaces",
    "st_plans",
    "st_cross_plan_edges",
    "st_claims",
    "st_resource_conflicts",
    "st_session_views",
    "st_workspace_apertures",
    "st_gcr_v2",
    "st_changesets",
    "st_integrations",
    "st_proof_invalidations",
    "st_legacy_artifacts",
    "st_findings",
    "st_decisions",
};

pub const workspaces_fields = [_][]const u8{ "workspace_id", "repo", "target_branch", "first_seen", "last_seen", "sequences", "branch_epochs", "plans", "storage_mode", "protocol_version", "evidence_refs" };
pub const plans_fields = [_][]const u8{ "workspace_id", "plan_id", "alias", "state", "source", "plan_sequences", "items", "intent", "debt", "proof_status", "first_seen", "last_seen", "evidence_refs" };
pub const cross_plan_edges_fields = [_][]const u8{ "workspace_id", "edge_id", "from", "to", "type", "state", "block_duration", "evidence_refs" };
pub const claims_fields = [_][]const u8{ "claim_id", "workspace_id", "plan_id", "session_id", "executor", "item_ids", "resources", "branch_epoch", "fencing_token", "state", "claimed_at", "expires_at", "released_at", "reclaimed_by", "evidence_refs" };
pub const resource_conflicts_fields = [_][]const u8{ "workspace_id", "candidate_claim", "other_claim", "resource_pairs", "decision", "evidence_refs" };
pub const session_views_fields = [_][]const u8{ "session_id", "workspace_id", "plan_id", "claim_id", "projection_digest", "selected_ids", "workspace_seq", "plan_seq", "branch_epoch", "state", "evidence_refs" };
pub const workspace_apertures_fields = [_][]const u8{ "workspace_id", "receipt_id", "allocations", "rejections", "parallel_width", "plans_considered", "fairness_state", "evidence_refs" };
pub const gcr_v2_fields = [_][]const u8{ "gcr_id", "workspace_id", "plan_id", "session_id", "claim_id", "fencing_token", "workspace_seq", "plan_seq", "branch_epoch", "selected_tasks", "execution_allowed", "denial_reasons", "current_at_mutation", "evidence_refs" };
pub const changesets_fields = [_][]const u8{ "change_set_id", "workspace_id", "plan_id", "claim_id", "base_head", "branch_epoch", "changed_paths", "uncovered_paths", "proof_refs", "status", "evidence_refs" };
pub const integrations_fields = [_][]const u8{ "change_set_id", "queue_sequence", "target_branch", "head_before", "head_after", "epoch_before", "epoch_after", "proof", "result", "latency", "evidence_refs" };
pub const proof_invalidations_fields = [_][]const u8{ "proof_ref", "plan_id", "scope", "epoch_before", "epoch_after", "foreign_change_set", "dependency_cut_intersection", "correctly_invalidated", "evidence_refs" };
pub const legacy_artifacts_fields = [_][]const u8{ "path", "session_id", "operation", "root", "classification", "actual_write", "evidence_refs" };
pub const findings_fields = [_][]const u8{ "severity", "code", "workspace_id", "plan_id", "session_id", "message", "evidence_refs" };
pub const decisions_fields = [_][]const u8{ "decision_id", "workspace_id", "plan_id", "session_id", "kind", "selected_route", "rejected_routes", "evidence_refs" };
pub const summary_fields = [_][]const u8{ "audit_version", "workspace_root", "workspaces", "plans", "claims", "conflicts", "gcr", "changesets", "integrations", "proof_invalidations", "legacy_writes", "p0", "p1", "p2", "info", "limitations" };

pub const Options = struct {
    root: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    workspace_root: ?[]const u8 = null,
    workspace_id: ?[]const u8 = null,
    plan_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    last: ?[]const u8 = null,
    exclude_current: bool = false,
};

const Evidence = struct {
    path: []const u8,
    line: usize,
    ref: []const u8,
};

const ClaimLite = struct {
    claim_id: []const u8,
    workspace_id: []const u8,
    plan_id: []const u8,
    session_id: []const u8,
    resources: []const u8,
    state: []const u8,
    evidence_refs: []const u8,
};

pub const RowSet = struct {
    allocator: std.mem.Allocator,
    workspaces: std.ArrayList(query.Row) = .empty,
    plans: std.ArrayList(query.Row) = .empty,
    cross_plan_edges: std.ArrayList(query.Row) = .empty,
    claims: std.ArrayList(query.Row) = .empty,
    resource_conflicts: std.ArrayList(query.Row) = .empty,
    session_views: std.ArrayList(query.Row) = .empty,
    workspace_apertures: std.ArrayList(query.Row) = .empty,
    gcr_v2: std.ArrayList(query.Row) = .empty,
    changesets: std.ArrayList(query.Row) = .empty,
    integrations: std.ArrayList(query.Row) = .empty,
    proof_invalidations: std.ArrayList(query.Row) = .empty,
    legacy_artifacts: std.ArrayList(query.Row) = .empty,
    findings: std.ArrayList(query.Row) = .empty,
    decisions: std.ArrayList(query.Row) = .empty,
    claim_index: std.ArrayList(ClaimLite) = .empty,

    pub fn init(allocator: std.mem.Allocator) RowSet {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RowSet) void {
        deinitRows(self.allocator, &self.workspaces);
        deinitRows(self.allocator, &self.plans);
        deinitRows(self.allocator, &self.cross_plan_edges);
        deinitRows(self.allocator, &self.claims);
        deinitRows(self.allocator, &self.resource_conflicts);
        deinitRows(self.allocator, &self.session_views);
        deinitRows(self.allocator, &self.workspace_apertures);
        deinitRows(self.allocator, &self.gcr_v2);
        deinitRows(self.allocator, &self.changesets);
        deinitRows(self.allocator, &self.integrations);
        deinitRows(self.allocator, &self.proof_invalidations);
        deinitRows(self.allocator, &self.legacy_artifacts);
        deinitRows(self.allocator, &self.findings);
        deinitRows(self.allocator, &self.decisions);
        for (self.claim_index.items) |item| {
            self.allocator.free(item.claim_id);
            self.allocator.free(item.workspace_id);
            self.allocator.free(item.plan_id);
            self.allocator.free(item.session_id);
            self.allocator.free(item.resources);
            self.allocator.free(item.state);
            self.allocator.free(item.evidence_refs);
        }
        self.claim_index.deinit(self.allocator);
    }

    fn deinitRows(allocator: std.mem.Allocator, rows: *std.ArrayList(query.Row)) void {
        for (rows.items) |*row| row.deinit();
        rows.deinit(allocator);
    }
};

pub fn isStWorkspaceDataset(name: []const u8) bool {
    for (dataset_names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

pub fn fieldsForDataset(name: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, name, "st_workspaces")) return workspaces_fields[0..];
    if (std.mem.eql(u8, name, "st_plans")) return plans_fields[0..];
    if (std.mem.eql(u8, name, "st_cross_plan_edges")) return cross_plan_edges_fields[0..];
    if (std.mem.eql(u8, name, "st_claims")) return claims_fields[0..];
    if (std.mem.eql(u8, name, "st_resource_conflicts")) return resource_conflicts_fields[0..];
    if (std.mem.eql(u8, name, "st_session_views")) return session_views_fields[0..];
    if (std.mem.eql(u8, name, "st_workspace_apertures")) return workspace_apertures_fields[0..];
    if (std.mem.eql(u8, name, "st_gcr_v2")) return gcr_v2_fields[0..];
    if (std.mem.eql(u8, name, "st_changesets")) return changesets_fields[0..];
    if (std.mem.eql(u8, name, "st_integrations")) return integrations_fields[0..];
    if (std.mem.eql(u8, name, "st_proof_invalidations")) return proof_invalidations_fields[0..];
    if (std.mem.eql(u8, name, "st_legacy_artifacts")) return legacy_artifacts_fields[0..];
    if (std.mem.eql(u8, name, "st_findings")) return findings_fields[0..];
    if (std.mem.eql(u8, name, "st_decisions")) return decisions_fields[0..];
    return null;
}

pub fn collect(allocator: std.mem.Allocator, opts: Options) !RowSet {
    var rows = RowSet.init(allocator);
    errdefer rows.deinit();

    if (opts.workspace_root) |root| {
        try scanWorkspaceRoot(allocator, root, opts, &rows);
    } else {
        try appendFinding(allocator, &rows, "INFO", "workspace_root_missing", opts.workspace_id orelse "", opts.plan_id orelse "", opts.session_id orelse "", "no --workspace-root supplied; only session legacy-write evidence was scanned", "[]");
    }
    if (opts.root) |root| try scanSessionRootForLegacyWrites(allocator, root, opts, &rows);
    try synthesizeConflictsAndFindings(allocator, &rows);
    return rows;
}

pub fn rowsForDataset(allocator: std.mem.Allocator, opts: Options, dataset_name: []const u8, out_rows: *std.ArrayList(query.Row)) !void {
    var rowset = try collect(allocator, opts);
    defer rowset.deinit();
    const source = datasetSlice(&rowset, dataset_name) orelse return error.UnknownDataset;
    for (source.items) |row| {
        try out_rows.append(allocator, try row.cloneAll(allocator));
    }
}

pub fn appendSummaryRow(allocator: std.mem.Allocator, rows: *std.ArrayList(query.Row), rowset: RowSet, workspace_root: ?[]const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try row.putOwnedKey("audit_version", .{ .string = audit_version });
    try row.putOwnedKey("workspace_root", if (workspace_root) |root| .{ .string = root } else .null);
    try row.putOwnedKey("workspaces", .{ .int = @intCast(rowset.workspaces.items.len) });
    try row.putOwnedKey("plans", .{ .int = @intCast(rowset.plans.items.len) });
    try row.putOwnedKey("claims", .{ .int = @intCast(rowset.claims.items.len) });
    try row.putOwnedKey("conflicts", .{ .int = @intCast(rowset.resource_conflicts.items.len) });
    try row.putOwnedKey("gcr", .{ .int = @intCast(rowset.gcr_v2.items.len) });
    try row.putOwnedKey("changesets", .{ .int = @intCast(rowset.changesets.items.len) });
    try row.putOwnedKey("integrations", .{ .int = @intCast(rowset.integrations.items.len) });
    try row.putOwnedKey("proof_invalidations", .{ .int = @intCast(rowset.proof_invalidations.items.len) });
    try row.putOwnedKey("legacy_writes", .{ .int = @intCast(countLegacyWrites(rowset)) });
    try row.putOwnedKey("p0", .{ .int = @intCast(countFindings(rowset, "P0")) });
    try row.putOwnedKey("p1", .{ .int = @intCast(countFindings(rowset, "P1")) });
    try row.putOwnedKey("p2", .{ .int = @intCast(countFindings(rowset, "P2")) });
    try row.putOwnedKey("info", .{ .int = @intCast(countFindings(rowset, "INFO")) });
    try row.putOwnedKey("limitations", .{ .string = if (workspace_root == null) "[\"workspace_root_missing\"]" else "[]" });
    try rows.append(allocator, row);
}

pub fn hasStrictFailure(rowset: RowSet) bool {
    for (rowset.findings.items) |row| {
        const severity = scalarString(row.valueOrNull("severity")) orelse continue;
        if (std.mem.eql(u8, severity, "P0") or std.mem.eql(u8, severity, "P1")) return true;
    }
    return false;
}

pub fn renderReport(allocator: std.mem.Allocator, rowset: RowSet, opts: Options, markdown: bool) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    if (markdown) {
        try writer.writeAll("# ST Workspace Audit\n\n");
        try writer.print("- audit_version: {s}\n", .{audit_version});
        if (opts.workspace_root) |root| try writer.print("- workspace_root: {s}\n", .{root});
        try writer.print("- workspaces: {d}\n", .{rowset.workspaces.items.len});
        try writer.print("- plans: {d}\n", .{rowset.plans.items.len});
        try writer.print("- claims: {d}\n", .{rowset.claims.items.len});
        try writer.print("- resource_conflicts: {d}\n", .{rowset.resource_conflicts.items.len});
        try writer.print("- gcr_v2: {d}\n", .{rowset.gcr_v2.items.len});
        try writer.print("- legacy_writes: {d}\n\n", .{countLegacyWrites(rowset)});
        try writer.writeAll("| severity | code | workspace_id | plan_id | session_id |\n");
        try writer.writeAll("| --- | --- | --- | --- | --- |\n");
        for (rowset.findings.items) |row| {
            try writer.print("| {s} | {s} | {s} | {s} | {s} |\n", .{
                scalarString(row.valueOrNull("severity")) orelse "",
                scalarString(row.valueOrNull("code")) orelse "",
                scalarString(row.valueOrNull("workspace_id")) orelse "",
                scalarString(row.valueOrNull("plan_id")) orelse "",
                scalarString(row.valueOrNull("session_id")) orelse "",
            });
        }
        return writer_alloc.toOwnedSlice();
    }

    try writer.writeAll("{\"st_workspace_audit\":{\"audit_version\":");
    try output.writeJsonString(writer, audit_version);
    try writer.writeAll(",\"corpus_snapshot\":{");
    try writer.writeAll("\"workspace_root\":");
    if (opts.workspace_root) |root| try output.writeJsonString(writer, root) else try writer.writeAll("null");
    try writer.print(",\"scanner_version\":\"{s}\"", .{scanner_version});
    try writer.writeAll("},\"workspace\":");
    try writeRowsJson(writer, rowset.workspaces.items, workspaces_fields[0..]);
    try writer.writeAll(",\"plans\":");
    try writeRowsJson(writer, rowset.plans.items, plans_fields[0..]);
    try writer.writeAll(",\"agents\":");
    try writeRowsJson(writer, rowset.session_views.items, session_views_fields[0..]);
    try writer.writeAll(",\"claims\":");
    try writeRowsJson(writer, rowset.claims.items, claims_fields[0..]);
    try writer.writeAll(",\"conflicts\":");
    try writeRowsJson(writer, rowset.resource_conflicts.items, resource_conflicts_fields[0..]);
    try writer.writeAll(",\"sessions\":");
    try writeRowsJson(writer, rowset.session_views.items, session_views_fields[0..]);
    try writer.writeAll(",\"apertures\":");
    try writeRowsJson(writer, rowset.workspace_apertures.items, workspace_apertures_fields[0..]);
    try writer.writeAll(",\"gcr\":");
    try writeRowsJson(writer, rowset.gcr_v2.items, gcr_v2_fields[0..]);
    try writer.writeAll(",\"changesets\":");
    try writeRowsJson(writer, rowset.changesets.items, changesets_fields[0..]);
    try writer.writeAll(",\"integration\":");
    try writeRowsJson(writer, rowset.integrations.items, integrations_fields[0..]);
    try writer.writeAll(",\"proof\":");
    try writeRowsJson(writer, rowset.proof_invalidations.items, proof_invalidations_fields[0..]);
    try writer.writeAll(",\"legacy_artifacts\":");
    try writeRowsJson(writer, rowset.legacy_artifacts.items, legacy_artifacts_fields[0..]);
    try writer.writeAll(",\"findings\":");
    try writeRowsJson(writer, rowset.findings.items, findings_fields[0..]);
    try writer.writeAll(",\"limitations\":");
    if (opts.workspace_root == null) try writer.writeAll("[\"workspace_root_missing\"]") else try writer.writeAll("[]");
    try writer.writeAll("}}\n");
    return writer_alloc.toOwnedSlice();
}

fn datasetSlice(rowset: *RowSet, name: []const u8) ?*std.ArrayList(query.Row) {
    if (std.mem.eql(u8, name, "st_workspaces")) return &rowset.workspaces;
    if (std.mem.eql(u8, name, "st_plans")) return &rowset.plans;
    if (std.mem.eql(u8, name, "st_cross_plan_edges")) return &rowset.cross_plan_edges;
    if (std.mem.eql(u8, name, "st_claims")) return &rowset.claims;
    if (std.mem.eql(u8, name, "st_resource_conflicts")) return &rowset.resource_conflicts;
    if (std.mem.eql(u8, name, "st_session_views")) return &rowset.session_views;
    if (std.mem.eql(u8, name, "st_workspace_apertures")) return &rowset.workspace_apertures;
    if (std.mem.eql(u8, name, "st_gcr_v2")) return &rowset.gcr_v2;
    if (std.mem.eql(u8, name, "st_changesets")) return &rowset.changesets;
    if (std.mem.eql(u8, name, "st_integrations")) return &rowset.integrations;
    if (std.mem.eql(u8, name, "st_proof_invalidations")) return &rowset.proof_invalidations;
    if (std.mem.eql(u8, name, "st_legacy_artifacts")) return &rowset.legacy_artifacts;
    if (std.mem.eql(u8, name, "st_findings")) return &rowset.findings;
    if (std.mem.eql(u8, name, "st_decisions")) return &rowset.decisions;
    return null;
}

fn scanWorkspaceRoot(allocator: std.mem.Allocator, root: []const u8, opts: Options, rows: *RowSet) !void {
    var root_dir = std.Io.Dir.openDirAbsolute(defaultIo(), root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try appendFinding(allocator, rows, "INFO", "workspace_root_unavailable", opts.workspace_id orelse "", opts.plan_id orelse "", opts.session_id orelse "", "workspace root could not be opened", "[]");
            return;
        },
        else => return err,
    };
    defer root_dir.close(defaultIo());

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!isArtifactFile(entry.path)) continue;
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, allocator, .limited(64 * 1024 * 1024)) catch continue;
        defer allocator.free(content);
        try scanArtifactContent(allocator, path, content, opts, rows);
    }
}

fn scanArtifactContent(allocator: std.mem.Allocator, path: []const u8, content: []const u8, opts: Options, rows: *RowSet) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;
    while (line_it.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] != '{' and line[0] != '[') continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const evidence = try evidenceRef(allocator, path, line_no, line);
        defer allocator.free(evidence);
        try scanJsonValue(allocator, parsed.value, path, line_no, evidence, opts, rows);
    }
}

fn scanJsonValue(allocator: std.mem.Allocator, value: std.json.Value, path: []const u8, line_no: usize, evidence: []const u8, opts: Options, rows: *RowSet) !void {
    switch (value) {
        .array => |arr| {
            for (arr.items, 0..) |item, idx| {
                const child_evidence = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ evidence, idx });
                defer allocator.free(child_evidence);
                try scanJsonValue(allocator, item, path, line_no, child_evidence, opts, rows);
            }
        },
        .object => |obj| {
            if (!objectPassesFilters(obj, opts)) return;
            if (isWorkspaceObject(obj)) try appendWorkspaceRow(allocator, rows, obj, evidence);
            if (isPlanObject(obj)) try appendPlanRow(allocator, rows, obj, evidence);
            if (isCrossPlanEdgeObject(obj)) try appendCrossPlanEdgeRow(allocator, rows, obj, evidence);
            if (isClaimObject(obj)) try appendClaimRow(allocator, rows, obj, evidence);
            if (isSessionViewObject(obj)) try appendSessionViewRow(allocator, rows, obj, evidence);
            if (isApertureObject(obj)) try appendApertureRow(allocator, rows, obj, evidence);
            if (isGcrObject(obj)) try appendGcrRow(allocator, rows, obj, evidence);
            if (isChangeSetObject(obj)) try appendChangeSetRow(allocator, rows, obj, evidence);
            if (isIntegrationObject(obj)) try appendIntegrationRow(allocator, rows, obj, evidence);
            if (isProofInvalidationObject(obj)) try appendProofInvalidationRow(allocator, rows, obj, evidence);
            if (isDecisionObject(obj)) try appendDecisionRow(allocator, rows, obj, evidence);
            if (jsonString(obj, "denial_reason") != null or jsonString(obj, "stale_fencing_token") != null or containsObjectText(obj, "stale-token")) {
                try appendFinding(allocator, rows, "P1", "stale_or_denied_operation", jsonString(obj, "workspace_id") orelse "", jsonString(obj, "plan_id") orelse "", jsonString(obj, "session_id") orelse "", "controller artifact recorded a stale or denied operation", evidence);
            }

            var it = obj.iterator();
            while (it.next()) |entry| try scanJsonValue(allocator, entry.value_ptr.*, path, line_no, evidence, opts, rows);
        },
        else => {},
    }
}

fn appendWorkspaceRow(allocator: std.mem.Allocator, rows: *RowSet, obj: std.json.ObjectMap, evidence: []const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putJsonString(&row, obj, "workspace_id", "workspace_id");
    try putJsonString(&row, obj, "repo", "repo");
    try putJsonString(&row, obj, "target_branch", "target_branch");
    try putJsonString(&row, obj, "first_seen", "first_seen");
    try putJsonString(&row, obj, "last_seen", "last_seen");
    try putJsonAny(allocator, &row, obj, "sequences", "sequences");
    try putJsonAny(allocator, &row, obj, "branch_epochs", "branch_epochs");
    try putJsonAny(allocator, &row, obj, "plans", "plans");
    try putJsonString(&row, obj, "storage_mode", "storage_mode");
    try putJsonString(&row, obj, "protocol_version", "protocol_version");
    try row.putOwnedKey("evidence_refs", .{ .string = evidence });
    try rows.workspaces.append(allocator, row);
}

fn appendPlanRow(allocator: std.mem.Allocator, rows: *RowSet, obj: std.json.ObjectMap, evidence: []const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putJsonString(&row, obj, "workspace_id", "workspace_id");
    try putJsonString(&row, obj, "plan_id", "plan_id");
    try putJsonString(&row, obj, "alias", "alias");
    try putJsonString(&row, obj, "state", "state");
    try putJsonString(&row, obj, "source", "source");
    try putJsonAny(allocator, &row, obj, "plan_sequences", "plan_sequences");
    try putJsonAny(allocator, &row, obj, "items", "items");
    try putJsonAny(allocator, &row, obj, "intent", "intent");
    try putJsonAny(allocator, &row, obj, "debt", "debt");
    try putJsonString(&row, obj, "proof_status", "proof_status");
    try putJsonString(&row, obj, "first_seen", "first_seen");
    try putJsonString(&row, obj, "last_seen", "last_seen");
    try row.putOwnedKey("evidence_refs", .{ .string = evidence });
    try rows.plans.append(allocator, row);
}

fn appendCrossPlanEdgeRow(allocator: std.mem.Allocator, rows: *RowSet, obj: std.json.ObjectMap, evidence: []const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putJsonString(&row, obj, "workspace_id", "workspace_id");
    try putJsonString(&row, obj, "edge_id", "edge_id");
    try putJsonString(&row, obj, "from", "from");
    try putJsonString(&row, obj, "to", "to");
    try putJsonString(&row, obj, "type", "type");
    try putJsonString(&row, obj, "state", "state");
    try putJsonString(&row, obj, "block_duration", "block_duration");
    try row.putOwnedKey("evidence_refs", .{ .string = evidence });
    try rows.cross_plan_edges.append(allocator, row);
}

fn appendClaimRow(allocator: std.mem.Allocator, rows: *RowSet, obj: std.json.ObjectMap, evidence: []const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putJsonString(&row, obj, "claim_id", "claim_id");
    try putJsonString(&row, obj, "workspace_id", "workspace_id");
    try putJsonString(&row, obj, "plan_id", "plan_id");
    try putJsonString(&row, obj, "session_id", "session_id");
    try putJsonString(&row, obj, "executor", "executor");
    try putJsonAny(allocator, &row, obj, "item_ids", "item_ids");
    try putJsonAny(allocator, &row, obj, "resources", "resources");
    try putJsonInt(&row, obj, "branch_epoch", "branch_epoch");
    try putJsonString(&row, obj, "fencing_token", "fencing_token");
    try putJsonString(&row, obj, "state", "state");
    try putJsonString(&row, obj, "claimed_at", "claimed_at");
    try putJsonString(&row, obj, "expires_at", "expires_at");
    try putJsonString(&row, obj, "released_at", "released_at");
    try putJsonString(&row, obj, "reclaimed_by", "reclaimed_by");
    try row.putOwnedKey("evidence_refs", .{ .string = evidence });
    try rows.claims.append(allocator, row);

    const resources = try jsonAnyString(allocator, obj.get("resources"));
    defer allocator.free(resources);
    try rows.claim_index.append(allocator, .{
        .claim_id = try allocator.dupe(u8, jsonString(obj, "claim_id") orelse ""),
        .workspace_id = try allocator.dupe(u8, jsonString(obj, "workspace_id") orelse ""),
        .plan_id = try allocator.dupe(u8, jsonString(obj, "plan_id") orelse ""),
        .session_id = try allocator.dupe(u8, jsonString(obj, "session_id") orelse ""),
        .resources = try allocator.dupe(u8, resources),
        .state = try allocator.dupe(u8, jsonString(obj, "state") orelse ""),
        .evidence_refs = try allocator.dupe(u8, evidence),
    });
}

fn appendSessionViewRow(allocator: std.mem.Allocator, rows: *RowSet, obj: std.json.ObjectMap, evidence: []const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putJsonString(&row, obj, "session_id", "session_id");
    try putJsonString(&row, obj, "workspace_id", "workspace_id");
    try putJsonString(&row, obj, "plan_id", "plan_id");
    try putJsonString(&row, obj, "claim_id", "claim_id");
    try putJsonString(&row, obj, "projection_digest", "projection_digest");
    try putJsonAny(allocator, &row, obj, "selected_ids", "selected_ids");
    try putJsonInt(&row, obj, "workspace_seq", "workspace_seq");
    try putJsonInt(&row, obj, "plan_seq", "plan_seq");
    try putJsonInt(&row, obj, "branch_epoch", "branch_epoch");
    try putJsonString(&row, obj, "state", "state");
    try row.putOwnedKey("evidence_refs", .{ .string = evidence });
    try rows.session_views.append(allocator, row);
}

fn appendApertureRow(allocator: std.mem.Allocator, rows: *RowSet, obj: std.json.ObjectMap, evidence: []const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putJsonString(&row, obj, "workspace_id", "workspace_id");
    try putJsonString(&row, obj, "receipt_id", "receipt_id");
    try putJsonAny(allocator, &row, obj, "allocations", "allocations");
    try putJsonAny(allocator, &row, obj, "rejections", "rejections");
    try putJsonInt(&row, obj, "parallel_width", "parallel_width");
    try putJsonAny(allocator, &row, obj, "plans_considered", "plans_considered");
    try putJsonAny(allocator, &row, obj, "fairness_state", "fairness_state");
    try row.putOwnedKey("evidence_refs", .{ .string = evidence });
    try rows.workspace_apertures.append(allocator, row);
}

fn appendGcrRow(allocator: std.mem.Allocator, rows: *RowSet, obj: std.json.ObjectMap, evidence: []const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putJsonStringAny(&row, obj, "gcr_id", &.{ "gcr_id", "receipt_id" });
    try putJsonString(&row, obj, "workspace_id", "workspace_id");
    try putJsonString(&row, obj, "plan_id", "plan_id");
    try putJsonString(&row, obj, "session_id", "session_id");
    try putJsonString(&row, obj, "claim_id", "claim_id");
    try putJsonString(&row, obj, "fencing_token", "fencing_token");
    try putJsonInt(&row, obj, "workspace_seq", "workspace_seq");
    try putJsonInt(&row, obj, "plan_seq", "plan_seq");
    try putJsonInt(&row, obj, "branch_epoch", "branch_epoch");
    try putJsonAny(allocator, &row, obj, "selected_tasks", "selected_tasks");
    try putJsonBool(&row, obj, "execution_allowed", "execution_allowed");
    try putJsonAny(allocator, &row, obj, "denial_reasons", "denial_reasons");
    try putJsonBool(&row, obj, "current_at_mutation", "current_at_mutation");
    try row.putOwnedKey("evidence_refs", .{ .string = evidence });
    try rows.gcr_v2.append(allocator, row);
}

fn appendChangeSetRow(allocator: std.mem.Allocator, rows: *RowSet, obj: std.json.ObjectMap, evidence: []const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putJsonString(&row, obj, "change_set_id", "change_set_id");
    try putJsonString(&row, obj, "workspace_id", "workspace_id");
    try putJsonString(&row, obj, "plan_id", "plan_id");
    try putJsonString(&row, obj, "claim_id", "claim_id");
    try putJsonString(&row, obj, "base_head", "base_head");
    try putJsonInt(&row, obj, "branch_epoch", "branch_epoch");
    try putJsonAny(allocator, &row, obj, "changed_paths", "changed_paths");
    try putJsonAny(allocator, &row, obj, "uncovered_paths", "uncovered_paths");
    try putJsonAny(allocator, &row, obj, "proof_refs", "proof_refs");
    try putJsonString(&row, obj, "status", "status");
    try row.putOwnedKey("evidence_refs", .{ .string = evidence });
    try rows.changesets.append(allocator, row);
    if (obj.get("uncovered_paths")) |value| {
        const text = try jsonAnyString(allocator, value);
        defer allocator.free(text);
        if (!std.mem.eql(u8, text, "[]") and text.len > 0) {
            try appendFinding(allocator, rows, "P1", "change_set_outside_claim", jsonString(obj, "workspace_id") orelse "", jsonString(obj, "plan_id") orelse "", "", "change set has uncovered paths outside claim coverage", evidence);
        }
    }
}

fn appendIntegrationRow(allocator: std.mem.Allocator, rows: *RowSet, obj: std.json.ObjectMap, evidence: []const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putJsonString(&row, obj, "change_set_id", "change_set_id");
    try putJsonInt(&row, obj, "queue_sequence", "queue_sequence");
    try putJsonString(&row, obj, "target_branch", "target_branch");
    try putJsonString(&row, obj, "head_before", "head_before");
    try putJsonString(&row, obj, "head_after", "head_after");
    try putJsonInt(&row, obj, "epoch_before", "epoch_before");
    try putJsonInt(&row, obj, "epoch_after", "epoch_after");
    try putJsonAny(allocator, &row, obj, "proof", "proof");
    try putJsonString(&row, obj, "result", "result");
    try putJsonString(&row, obj, "latency", "latency");
    try row.putOwnedKey("evidence_refs", .{ .string = evidence });
    try rows.integrations.append(allocator, row);
}

fn appendProofInvalidationRow(allocator: std.mem.Allocator, rows: *RowSet, obj: std.json.ObjectMap, evidence: []const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putJsonString(&row, obj, "proof_ref", "proof_ref");
    try putJsonString(&row, obj, "plan_id", "plan_id");
    try putJsonString(&row, obj, "scope", "scope");
    try putJsonInt(&row, obj, "epoch_before", "epoch_before");
    try putJsonInt(&row, obj, "epoch_after", "epoch_after");
    try putJsonString(&row, obj, "foreign_change_set", "foreign_change_set");
    try putJsonBool(&row, obj, "dependency_cut_intersection", "dependency_cut_intersection");
    try putJsonBool(&row, obj, "correctly_invalidated", "correctly_invalidated");
    try row.putOwnedKey("evidence_refs", .{ .string = evidence });
    try rows.proof_invalidations.append(allocator, row);
    if (jsonBool(obj, "correctly_invalidated") == false) {
        try appendFinding(allocator, rows, "P2", "missing_or_wrong_proof_invalidation", "", jsonString(obj, "plan_id") orelse "", "", "proof invalidation receipt is not correct for the reconstructed dependency cut", evidence);
    }
}

fn appendDecisionRow(allocator: std.mem.Allocator, rows: *RowSet, obj: std.json.ObjectMap, evidence: []const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putJsonStringAny(&row, obj, "decision_id", &.{ "decision_id", "receipt_id" });
    try putJsonString(&row, obj, "workspace_id", "workspace_id");
    try putJsonString(&row, obj, "plan_id", "plan_id");
    try putJsonString(&row, obj, "session_id", "session_id");
    try putJsonStringAny(&row, obj, "kind", &.{ "decision_kind", "kind", "type" });
    try putJsonStringAny(&row, obj, "selected_route", &.{ "selected_route", "decision", "result" });
    try putJsonAny(allocator, &row, obj, "rejected_routes", "rejected_routes");
    try row.putOwnedKey("evidence_refs", .{ .string = evidence });
    try rows.decisions.append(allocator, row);
}

fn scanSessionRootForLegacyWrites(allocator: std.mem.Allocator, root: []const u8, opts: Options, rows: *RowSet) !void {
    var root_dir = std.Io.Dir.openDirAbsolute(defaultIo(), root, .{ .iterate = true }) catch return;
    defer root_dir.close(defaultIo());

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(defaultIo())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".jsonl")) continue;
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, allocator, .limited(64 * 1024 * 1024)) catch continue;
        defer allocator.free(content);
        try scanLegacyContent(allocator, path, content, opts, rows);
    }
}

fn scanLegacyContent(allocator: std.mem.Allocator, path: []const u8, content: []const u8, opts: Options, rows: *RowSet) !void {
    var it = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        if (!legacyWriteLine(line)) continue;
        if (opts.session_id) |session_id| {
            if (std.mem.indexOf(u8, line, session_id) == null) continue;
        }
        const evidence = try evidenceRef(allocator, path, line_no, line);
        defer allocator.free(evidence);
        const root = if (std.mem.indexOf(u8, line, ".retrace/") != null) ".retrace/" else ".step/";
        var row = query.Row.init(allocator);
        errdefer row.deinit();
        try row.putOwnedKey("path", .{ .string = path });
        try row.putOwnedKey("session_id", .{ .string = opts.session_id orelse "" });
        try row.putOwnedKey("operation", .{ .string = "write_attempt" });
        try row.putOwnedKey("root", .{ .string = root });
        try row.putOwnedKey("classification", .{ .string = "post_migration_legacy_write" });
        try row.putOwnedKey("actual_write", .{ .bool = true });
        try row.putOwnedKey("evidence_refs", .{ .string = evidence });
        try rows.legacy_artifacts.append(allocator, row);
        try appendFinding(allocator, rows, "P2", "legacy_artifact_write", "", "", opts.session_id orelse "", "actual write attempt to legacy .step/.retrace root after ledger-root activation", evidence);
    }
}

fn synthesizeConflictsAndFindings(allocator: std.mem.Allocator, rows: *RowSet) !void {
    for (rows.claim_index.items, 0..) |left, i| {
        if (!heldClaimState(left.state)) continue;
        for (rows.claim_index.items[i + 1 ..]) |right| {
            if (!heldClaimState(right.state)) continue;
            if (!std.mem.eql(u8, left.workspace_id, right.workspace_id)) continue;
            const pair = try overlappingResources(allocator, left.resources, right.resources);
            defer allocator.free(pair);
            if (pair.len == 0) continue;
            const evidence = try std.fmt.allocPrint(allocator, "[{s},{s}]", .{ left.evidence_refs, right.evidence_refs });
            defer allocator.free(evidence);
            var row = query.Row.init(allocator);
            errdefer row.deinit();
            try row.putOwnedKey("workspace_id", .{ .string = left.workspace_id });
            try row.putOwnedKey("candidate_claim", .{ .string = right.claim_id });
            try row.putOwnedKey("other_claim", .{ .string = left.claim_id });
            try row.putOwnedKey("resource_pairs", .{ .string = pair });
            try row.putOwnedKey("decision", .{ .string = "unsafe_grant" });
            try row.putOwnedKey("evidence_refs", .{ .string = evidence });
            try rows.resource_conflicts.append(allocator, row);
            try appendFinding(allocator, rows, "P0", "two_conflicting_claims_held", left.workspace_id, right.plan_id, right.session_id, "overlapping held claims were reconstructed without a denial/serialization receipt", evidence);
        }
    }
}

fn appendFinding(allocator: std.mem.Allocator, rows: *RowSet, severity: []const u8, code: []const u8, workspace_id: []const u8, plan_id: []const u8, session_id: []const u8, message: []const u8, evidence: []const u8) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try row.putOwnedKey("severity", .{ .string = severity });
    try row.putOwnedKey("code", .{ .string = code });
    try row.putOwnedKey("workspace_id", .{ .string = workspace_id });
    try row.putOwnedKey("plan_id", .{ .string = plan_id });
    try row.putOwnedKey("session_id", .{ .string = session_id });
    try row.putOwnedKey("message", .{ .string = message });
    try row.putOwnedKey("evidence_refs", .{ .string = evidence });
    try rows.findings.append(allocator, row);
}

fn writeRowsJson(writer: anytype, rows: []const query.Row, fields: []const []const u8) !void {
    try writer.writeByte('[');
    for (rows, 0..) |row, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        for (fields, 0..) |field, fidx| {
            if (fidx > 0) try writer.writeByte(',');
            try output.writeJsonString(writer, field);
            try writer.writeByte(':');
            try output.writeScalarJson(writer, row.valueOrNull(field));
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn isWorkspaceObject(obj: std.json.ObjectMap) bool {
    return obj.get("workspace_id") != null and (obj.get("target_branch") != null or obj.get("branch_epochs") != null or obj.get("storage_mode") != null);
}

fn isPlanObject(obj: std.json.ObjectMap) bool {
    return obj.get("plan_id") != null and (obj.get("items") != null or obj.get("plan_sequences") != null or obj.get("proof_status") != null);
}

fn isCrossPlanEdgeObject(obj: std.json.ObjectMap) bool {
    return obj.get("edge_id") != null and obj.get("from") != null and obj.get("to") != null;
}

fn isClaimObject(obj: std.json.ObjectMap) bool {
    return obj.get("claim_id") != null and
        (obj.get("resources") != null or
            obj.get("claimed_at") != null or
            obj.get("expires_at") != null or
            obj.get("released_at") != null or
            obj.get("reclaimed_by") != null);
}

fn isSessionViewObject(obj: std.json.ObjectMap) bool {
    return obj.get("projection_digest") != null or (obj.get("selected_ids") != null and obj.get("session_id") != null and obj.get("workspace_seq") != null);
}

fn isApertureObject(obj: std.json.ObjectMap) bool {
    return obj.get("allocations") != null and (obj.get("parallel_width") != null or obj.get("plans_considered") != null);
}

fn isGcrObject(obj: std.json.ObjectMap) bool {
    if (jsonString(obj, "receipt_version")) |version| {
        if (std.mem.eql(u8, version, "GCR-v2")) return true;
    }
    return obj.get("gcr_id") != null or (obj.get("execution_allowed") != null and obj.get("selected_tasks") != null);
}

fn isChangeSetObject(obj: std.json.ObjectMap) bool {
    return obj.get("change_set_id") != null and (obj.get("changed_paths") != null or obj.get("base_head") != null);
}

fn isIntegrationObject(obj: std.json.ObjectMap) bool {
    return obj.get("head_before") != null and obj.get("head_after") != null and obj.get("change_set_id") != null;
}

fn isProofInvalidationObject(obj: std.json.ObjectMap) bool {
    return obj.get("proof_ref") != null and (obj.get("foreign_change_set") != null or obj.get("correctly_invalidated") != null);
}

fn isDecisionObject(obj: std.json.ObjectMap) bool {
    if (obj.get("decision_id") == null and obj.get("receipt_id") == null) return false;
    if (jsonString(obj, "kind")) |kind| return isDecisionKind(kind);
    if (jsonString(obj, "decision_kind")) |kind| return isDecisionKind(kind);
    return false;
}

fn isDecisionKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "plan_selection") or
        std.mem.eql(u8, kind, "cross_plan_edge") or
        std.mem.eql(u8, kind, "workspace_allocation") or
        std.mem.eql(u8, kind, "claim_grant") or
        std.mem.eql(u8, kind, "claim_deny") or
        std.mem.eql(u8, kind, "claim_amend") or
        std.mem.eql(u8, kind, "claim_reclaim") or
        std.mem.eql(u8, kind, "resource_expansion") or
        std.mem.eql(u8, kind, "return_to_workspace") or
        std.mem.eql(u8, kind, "changeset_reject") or
        std.mem.eql(u8, kind, "changeset_supersede") or
        std.mem.eql(u8, kind, "integration_accept") or
        std.mem.eql(u8, kind, "integration_block") or
        std.mem.eql(u8, kind, "proof_invalidation") or
        std.mem.eql(u8, kind, "migration");
}

fn objectPassesFilters(obj: std.json.ObjectMap, opts: Options) bool {
    if (opts.workspace_id) |expected| {
        if (jsonString(obj, "workspace_id")) |actual| {
            if (!std.mem.eql(u8, actual, expected)) return false;
        }
    }
    if (opts.plan_id) |expected| {
        if (jsonString(obj, "plan_id")) |actual| {
            if (!std.mem.eql(u8, actual, expected)) return false;
        }
    }
    if (opts.session_id) |expected| {
        if (jsonString(obj, "session_id")) |actual| {
            if (!std.mem.eql(u8, actual, expected)) return false;
        }
    }
    if (opts.repo) |expected| {
        if (jsonString(obj, "repo")) |actual| {
            if (std.mem.indexOf(u8, actual, expected) == null and std.mem.indexOf(u8, expected, actual) == null) return false;
        }
    }
    _ = opts.since;
    _ = opts.until;
    _ = opts.last;
    _ = opts.exclude_current;
    return true;
}

fn putJsonString(row: *query.Row, obj: std.json.ObjectMap, out_key: []const u8, json_key: []const u8) !void {
    if (jsonString(obj, json_key)) |text| try row.putOwnedKey(out_key, .{ .string = text }) else try row.putOwnedKey(out_key, .null);
}

fn putJsonStringAny(row: *query.Row, obj: std.json.ObjectMap, out_key: []const u8, json_keys: []const []const u8) !void {
    for (json_keys) |key| {
        if (jsonString(obj, key)) |text| {
            try row.putOwnedKey(out_key, .{ .string = text });
            return;
        }
    }
    try row.putOwnedKey(out_key, .null);
}

fn putJsonInt(row: *query.Row, obj: std.json.ObjectMap, out_key: []const u8, json_key: []const u8) !void {
    if (jsonInt(obj, json_key)) |value| try row.putOwnedKey(out_key, .{ .int = value }) else try row.putOwnedKey(out_key, .null);
}

fn putJsonBool(row: *query.Row, obj: std.json.ObjectMap, out_key: []const u8, json_key: []const u8) !void {
    if (jsonBool(obj, json_key)) |value| try row.putOwnedKey(out_key, .{ .bool = value }) else try row.putOwnedKey(out_key, .null);
}

fn putJsonAny(allocator: std.mem.Allocator, row: *query.Row, obj: std.json.ObjectMap, out_key: []const u8, json_key: []const u8) !void {
    const text = try jsonAnyString(allocator, obj.get(json_key));
    defer allocator.free(text);
    if (text.len == 0) try row.putOwnedKey(out_key, .null) else try row.putOwnedKey(out_key, .{ .string = text });
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn jsonAnyString(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]u8 {
    const value = value_opt orelse return allocator.dupe(u8, "");
    switch (value) {
        .string => |text| return allocator.dupe(u8, text),
        .integer => |number| return std.fmt.allocPrint(allocator, "{d}", .{number}),
        .float => |number| return std.fmt.allocPrint(allocator, "{d}", .{number}),
        .bool => |flag| return allocator.dupe(u8, if (flag) "true" else "false"),
        .null => return allocator.dupe(u8, ""),
        else => {
            var writer_alloc = std.Io.Writer.Allocating.init(allocator);
            defer writer_alloc.deinit();
            try std.json.Stringify.value(value, .{}, &writer_alloc.writer);
            return writer_alloc.toOwnedSlice();
        },
    }
}

fn containsObjectText(obj: std.json.ObjectMap, needle: []const u8) bool {
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .string and std.mem.indexOf(u8, entry.value_ptr.string, needle) != null) return true;
    }
    return false;
}

fn legacyWriteLine(line: []const u8) bool {
    const has_legacy = std.mem.indexOf(u8, line, ".step/") != null or std.mem.indexOf(u8, line, ".retrace/") != null;
    if (!has_legacy) return false;
    if (std.mem.indexOf(u8, line, "artifact-under-repair") != null) return false;
    if (std.mem.indexOf(u8, line, "*** Add File: .step/") != null or
        std.mem.indexOf(u8, line, "*** Update File: .step/") != null or
        std.mem.indexOf(u8, line, "*** Delete File: .step/") != null or
        std.mem.indexOf(u8, line, "*** Add File: .retrace/") != null or
        std.mem.indexOf(u8, line, "*** Update File: .retrace/") != null or
        std.mem.indexOf(u8, line, "*** Delete File: .retrace/") != null)
    {
        return true;
    }
    if (std.mem.indexOf(u8, line, "writeFile") != null or
        std.mem.indexOf(u8, line, "mkdir") != null or
        std.mem.indexOf(u8, line, "tee ") != null or
        std.mem.indexOf(u8, line, "> .step/") != null or
        std.mem.indexOf(u8, line, "> .retrace/") != null)
    {
        return true;
    }
    return false;
}

fn heldClaimState(state: []const u8) bool {
    return state.len == 0 or std.mem.eql(u8, state, "held") or std.mem.eql(u8, state, "granted") or std.mem.eql(u8, state, "active");
}

fn overlappingResources(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]u8 {
    var left_tokens = std.mem.tokenizeAny(u8, left, "[]{}\", \t\r\n:");
    while (left_tokens.next()) |left_token| {
        if (!resourceToken(left_token)) continue;
        var right_tokens = std.mem.tokenizeAny(u8, right, "[]{}\", \t\r\n:");
        while (right_tokens.next()) |right_token| {
            if (!resourceToken(right_token)) continue;
            if (resourcesOverlap(left_token, right_token)) {
                return std.fmt.allocPrint(allocator, "[\"{s}<->{s}\"]", .{ left_token, right_token });
            }
        }
    }
    return allocator.dupe(u8, "");
}

fn resourceToken(text: []const u8) bool {
    if (text.len < 2) return false;
    if (std.mem.eql(u8, text, "path") or std.mem.eql(u8, text, "symbol") or std.mem.eql(u8, text, "resource")) return false;
    return std.mem.indexOfScalar(u8, text, '/') != null or std.mem.indexOfScalar(u8, text, '.') != null or std.mem.indexOf(u8, text, "::") != null;
}

fn resourcesOverlap(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    return pathPrefixOverlap(left, right) or pathPrefixOverlap(right, left);
}

fn pathPrefixOverlap(parent: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child.len == parent.len or child[parent.len] == '/';
}

fn isArtifactFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".json") or
        std.mem.endsWith(u8, path, ".jsonl") or
        std.mem.endsWith(u8, path, ".receipt");
}

fn evidenceRef(allocator: std.mem.Allocator, path: []const u8, line_no: usize, content: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    var buf: [32]u8 = undefined;
    const line_text = try std.fmt.bufPrint(buf[0..], "{d}", .{line_no});
    hasher.update(line_text);
    hasher.update(content);
    return std.fmt.allocPrint(allocator, "STWA-{x:0>16}", .{hasher.final()});
}

fn countFindings(rowset: RowSet, severity: []const u8) usize {
    var count: usize = 0;
    for (rowset.findings.items) |row| {
        if (scalarString(row.valueOrNull("severity"))) |actual| {
            if (std.mem.eql(u8, actual, severity)) count += 1;
        }
    }
    return count;
}

fn countLegacyWrites(rowset: RowSet) usize {
    var count: usize = 0;
    for (rowset.legacy_artifacts.items) |row| {
        if (row.valueOrNull("actual_write") == .bool and row.valueOrNull("actual_write").bool) count += 1;
    }
    return count;
}

fn scalarString(value: spec.Scalar) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
