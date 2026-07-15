const std = @import("std");
const skill_contract = @import("skill_contract.zig");

pub const Receipt = struct {
    receipt_version: []const u8 = "",
    decision_id: []const u8 = "",
    skill: []const u8 = "",
    skill_version: []const u8 = "",
    skill_contract_fingerprint: []const u8 = "",
    trigger_refs: []const []const u8 = &.{},
    clause_refs: []const []const u8 = &.{},
    question: []const u8 = "",
    alternatives_considered: []const []const u8 = &.{},
    selected_route: []const u8 = "",
    rejected_routes: []const []const u8 = &.{},
    expected_outcome: []const u8 = "",
    artifact_state_present: bool = false,
    artifact_state_json: []const u8 = "null",
    evidence_refs: []const []const u8 = &.{},
};

pub const ParsedReceipt = struct {
    arena: std.heap.ArenaAllocator,
    receipt: Receipt,

    pub fn deinit(self: *ParsedReceipt) void {
        self.arena.deinit();
    }
};

pub const ValidationReport = struct {
    valid: bool,
    codes: []const []const u8,
    canonical_hash: ?[]const u8,

    pub fn deinit(self: ValidationReport, allocator: std.mem.Allocator) void {
        allocator.free(self.codes);
        if (self.canonical_hash) |hash| allocator.free(hash);
    }
};

pub fn parseText(allocator: std.mem.Allocator, raw_text: []const u8) !ParsedReceipt {
    const raw_trimmed = std.mem.trim(u8, raw_text, " \t\r\n");
    if (raw_trimmed.len > 0 and raw_trimmed[0] == '{') return parseJsonText(allocator, raw_trimmed);
    const text = extractReceiptText(raw_trimmed) orelse return error.InvalidSpec;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidSpec;
    if (trimmed[0] == '{') return parseJsonText(allocator, trimmed);
    return parseYamlText(allocator, trimmed);
}

pub fn validateText(
    allocator: std.mem.Allocator,
    text: []const u8,
    target_skill: ?[]const u8,
    contract: ?skill_contract.Contract,
) !ValidationReport {
    var parsed = try parseText(allocator, text);
    defer parsed.deinit();
    return validateParsed(allocator, parsed.receipt, target_skill, contract);
}

pub fn validateParsed(
    allocator: std.mem.Allocator,
    receipt: Receipt,
    target_skill: ?[]const u8,
    contract: ?skill_contract.Contract,
) !ValidationReport {
    var codes: std.ArrayList([]const u8) = .empty;
    defer codes.deinit(allocator);
    if (!std.mem.eql(u8, receipt.receipt_version, "SDR-v1")) try codes.append(allocator, "invalid_receipt_version");
    if (!isStableDecisionId(receipt.decision_id)) try codes.append(allocator, "invalid_decision_id");
    if (receipt.skill.len == 0) try codes.append(allocator, "missing_skill");
    if (target_skill) |skill| {
        if (!std.mem.eql(u8, receipt.skill, skill)) try codes.append(allocator, "skill_mismatch");
    }
    if (receipt.selected_route.len == 0) try codes.append(allocator, "missing_selected_route");
    for (receipt.rejected_routes) |route| {
        if (std.mem.eql(u8, route, receipt.selected_route)) try codes.append(allocator, "selected_route_rejected");
    }
    if (!receipt.artifact_state_present) try codes.append(allocator, "missing_artifact_state");

    if (contract) |c| {
        if (receipt.skill_contract_fingerprint.len == 0) {
            try codes.append(allocator, "missing_skill_contract_fingerprint");
        } else {
            const contract_fingerprint = try skill_contract.fingerprintContract(allocator, c);
            defer allocator.free(contract_fingerprint);
            if (!std.mem.eql(u8, receipt.skill_contract_fingerprint, contract_fingerprint)) {
                try codes.append(allocator, "skill_contract_fingerprint_mismatch");
            }
        }

        var trigger_ids = std.StringHashMap(void).init(allocator);
        defer trigger_ids.deinit();
        for (c.triggers) |trigger| try trigger_ids.put(trigger.trigger_id, {});
        var clause_ids = std.StringHashMap(void).init(allocator);
        defer clause_ids.deinit();
        for (c.clauses) |clause| try clause_ids.put(clause.clause_id, {});
        var route_ids = std.StringHashMap(void).init(allocator);
        defer route_ids.deinit();
        for (c.routes) |route| try route_ids.put(route.route_id, {});
        for (receipt.trigger_refs) |id| if (!trigger_ids.contains(id)) try codes.append(allocator, "unknown_trigger_ref");
        for (receipt.clause_refs) |id| if (!clause_ids.contains(id)) try codes.append(allocator, "unknown_clause_ref");
        if (receipt.selected_route.len > 0 and !route_ids.contains(receipt.selected_route)) try codes.append(allocator, "unknown_selected_route");
        for (receipt.rejected_routes) |id| if (!route_ids.contains(id)) try codes.append(allocator, "unknown_rejected_route");
    }

    const valid = codes.items.len == 0;
    const canonical_hash = if (valid) try fingerprintReceipt(allocator, receipt) else null;
    return .{
        .valid = valid,
        .codes = try allocator.dupe([]const u8, codes.items),
        .canonical_hash = canonical_hash,
    };
}

pub fn fingerprintReceipt(allocator: std.mem.Allocator, receipt: Receipt) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    try writeCanonicalReceipt(&writer_alloc.writer, receipt);
    const canonical = try writer_alloc.toOwnedSlice();
    defer allocator.free(canonical);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, hex[0..]);
}

fn parseJsonText(allocator: std.mem.Allocator, text: []const u8) !ParsedReceipt {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parsed_json = try std.json.parseFromSlice(std.json.Value, arena.allocator(), text, .{});
    defer parsed_json.deinit();
    const root = objectValue(parsed_json.value) orelse return error.InvalidSpec;
    const receipt_value = root.get("skill_decision_receipt") orelse return error.InvalidSpec;
    const receipt = try parseReceiptValue(arena.allocator(), receipt_value);
    return .{ .arena = arena, .receipt = receipt };
}

fn parseReceiptValue(allocator: std.mem.Allocator, value: std.json.Value) !Receipt {
    const obj = objectValue(value) orelse return error.InvalidSpec;
    return .{
        .receipt_version = try dupStringField(allocator, obj, "receipt_version", ""),
        .decision_id = try dupStringField(allocator, obj, "decision_id", ""),
        .skill = try dupStringField(allocator, obj, "skill", ""),
        .skill_version = try dupStringField(allocator, obj, "skill_version", ""),
        .skill_contract_fingerprint = try dupStringField(allocator, obj, "skill_contract_fingerprint", ""),
        .trigger_refs = try dupStringArrayField(allocator, obj, "trigger_refs"),
        .clause_refs = try dupStringArrayField(allocator, obj, "clause_refs"),
        .question = try dupStringField(allocator, obj, "question", ""),
        .alternatives_considered = try dupStringArrayField(allocator, obj, "alternatives_considered"),
        .selected_route = try dupStringField(allocator, obj, "selected_route", ""),
        .rejected_routes = try dupStringArrayField(allocator, obj, "rejected_routes"),
        .expected_outcome = try dupStringField(allocator, obj, "expected_outcome", ""),
        .artifact_state_present = obj.get("artifact_state") != null,
        .artifact_state_json = try dupJsonFieldCanonical(allocator, obj, "artifact_state", "null"),
        .evidence_refs = try dupStringArrayField(allocator, obj, "evidence_refs"),
    };
}

fn parseYamlText(allocator: std.mem.Allocator, text: []const u8) !ParsedReceipt {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var receipt = Receipt{};
    var in_receipt = false;
    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw_line| {
        const no_cr = std.mem.trim(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, no_cr, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const indent = countIndent(no_cr);
        if (indent == 0) {
            if (!std.mem.eql(u8, trimmed, "skill_decision_receipt:")) return error.InvalidSpec;
            in_receipt = true;
            continue;
        }
        if (!in_receipt or indent != 2) return error.InvalidSpec;
        const kv = splitYamlKeyValue(trimmed) orelse return error.InvalidSpec;
        if (std.mem.eql(u8, kv.key, "receipt_version")) receipt.receipt_version = try dupYamlScalar(aa, kv.value) else if (std.mem.eql(u8, kv.key, "decision_id")) receipt.decision_id = try dupYamlScalar(aa, kv.value) else if (std.mem.eql(u8, kv.key, "skill")) receipt.skill = try dupYamlScalar(aa, kv.value) else if (std.mem.eql(u8, kv.key, "skill_version")) receipt.skill_version = try dupYamlScalar(aa, kv.value) else if (std.mem.eql(u8, kv.key, "skill_contract_fingerprint")) receipt.skill_contract_fingerprint = try dupYamlScalar(aa, kv.value) else if (std.mem.eql(u8, kv.key, "trigger_refs")) receipt.trigger_refs = try parseYamlInlineList(aa, kv.value) else if (std.mem.eql(u8, kv.key, "clause_refs")) receipt.clause_refs = try parseYamlInlineList(aa, kv.value) else if (std.mem.eql(u8, kv.key, "question")) receipt.question = try dupYamlScalar(aa, kv.value) else if (std.mem.eql(u8, kv.key, "alternatives_considered")) receipt.alternatives_considered = try parseYamlInlineList(aa, kv.value) else if (std.mem.eql(u8, kv.key, "selected_route")) receipt.selected_route = try dupYamlScalar(aa, kv.value) else if (std.mem.eql(u8, kv.key, "rejected_routes")) receipt.rejected_routes = try parseYamlInlineList(aa, kv.value) else if (std.mem.eql(u8, kv.key, "expected_outcome")) receipt.expected_outcome = try dupYamlScalar(aa, kv.value) else if (std.mem.eql(u8, kv.key, "artifact_state")) {
            receipt.artifact_state_present = true;
            receipt.artifact_state_json = try aa.dupe(u8, if (kv.value.len == 0) "{}" else kv.value);
        } else if (std.mem.eql(u8, kv.key, "evidence_refs")) receipt.evidence_refs = try parseYamlInlineList(aa, kv.value);
    }
    return .{ .arena = arena, .receipt = receipt };
}

fn extractReceiptText(text: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, text, "skill_decision_receipt")) |idx| {
        var start = idx;
        while (start > 0 and text[start - 1] != '\n' and text[start - 1] != '{') : (start -= 1) {}
        if (start > 0 and text[start - 1] == '{') return text[start - 1 ..];
        if (text[start] == '{') return text[start..];
        return text[idx..];
    }
    return null;
}

fn writeCanonicalReceipt(writer: anytype, receipt: Receipt) !void {
    try writer.writeAll("{\"skill_decision_receipt\":{\"alternatives_considered\":");
    try writeJsonStringArray(writer, receipt.alternatives_considered);
    try writer.writeAll(",\"artifact_state\":");
    try writer.writeAll(if (receipt.artifact_state_present) receipt.artifact_state_json else "null");
    try writer.writeAll(",\"clause_refs\":");
    try writeJsonStringArray(writer, receipt.clause_refs);
    try writer.writeAll(",\"decision_id\":");
    try writeJsonString(writer, receipt.decision_id);
    try writer.writeAll(",\"evidence_refs\":");
    try writeJsonStringArray(writer, receipt.evidence_refs);
    try writer.writeAll(",\"expected_outcome\":");
    try writeJsonString(writer, receipt.expected_outcome);
    try writer.writeAll(",\"question\":");
    try writeJsonString(writer, receipt.question);
    try writer.writeAll(",\"receipt_version\":");
    try writeJsonString(writer, receipt.receipt_version);
    try writer.writeAll(",\"rejected_routes\":");
    try writeJsonStringArray(writer, receipt.rejected_routes);
    try writer.writeAll(",\"selected_route\":");
    try writeJsonString(writer, receipt.selected_route);
    try writer.writeAll(",\"skill\":");
    try writeJsonString(writer, receipt.skill);
    try writer.writeAll(",\"skill_contract_fingerprint\":");
    try writeJsonString(writer, receipt.skill_contract_fingerprint);
    try writer.writeAll(",\"skill_version\":");
    try writeJsonString(writer, receipt.skill_version);
    try writer.writeAll(",\"trigger_refs\":");
    try writeJsonStringArray(writer, receipt.trigger_refs);
    try writer.writeAll("}}");
}

fn objectValue(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn dupStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return allocator.dupe(u8, default);
    return switch (value) {
        .null => try allocator.dupe(u8, default),
        .string => |text| try allocator.dupe(u8, text),
        else => error.InvalidSpec,
    };
}

fn dupJsonFieldCanonical(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return allocator.dupe(u8, default);
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn dupStringArrayField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = obj.get(key) orelse return &.{};
    const arr = switch (value) {
        .array => |arr| arr,
        else => return error.InvalidSpec,
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (arr.items) |item| {
        if (item != .string) return error.InvalidSpec;
        try out.append(allocator, try allocator.dupe(u8, item.string));
    }
    return out.toOwnedSlice(allocator);
}

fn splitYamlKeyValue(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const idx = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    return .{
        .key = std.mem.trim(u8, line[0..idx], " \t"),
        .value = std.mem.trim(u8, line[idx + 1 ..], " \t"),
    };
}

fn countIndent(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

fn dupYamlScalar(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const scalar = std.mem.trim(u8, raw, " \t");
    if (scalar.len >= 2 and ((scalar[0] == '"' and scalar[scalar.len - 1] == '"') or (scalar[0] == '\'' and scalar[scalar.len - 1] == '\''))) {
        return allocator.dupe(u8, scalar[1 .. scalar.len - 1]);
    }
    return allocator.dupe(u8, scalar);
}

fn parseYamlInlineList(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    const text = std.mem.trim(u8, raw, " \t");
    if (std.mem.eql(u8, text, "[]") or text.len == 0) return &.{};
    if (text.len < 2 or text[0] != '[' or text[text.len - 1] != ']') return error.InvalidSpec;
    const inner = std.mem.trim(u8, text[1 .. text.len - 1], " \t");
    if (inner.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, inner, ',');
    while (split.next()) |part| {
        const scalar = try dupYamlScalar(allocator, part);
        if (scalar.len == 0) return error.InvalidSpec;
        try out.append(allocator, scalar);
    }
    return out.toOwnedSlice(allocator);
}

fn writeJsonStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeByte(']');
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn isStableDecisionId(text: []const u8) bool {
    if (text.len < 3) return false;
    for (text) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == ':')) return false;
    }
    return true;
}

pub fn containsCode(codes: []const []const u8, needle: []const u8) bool {
    for (codes) |code| if (std.mem.eql(u8, code, needle)) return true;
    return false;
}

test "valid SDR JSON and YAML validate" {
    const json =
        \\{"skill_decision_receipt":{"receipt_version":"SDR-v1","decision_id":"dec-1","skill":"team-patterns","skill_version":"1","skill_contract_fingerprint":"fp","trigger_refs":["t1"],"clause_refs":["c1"],"question":"choose","alternatives_considered":["a"],"selected_route":"r1","rejected_routes":["r2"],"expected_outcome":"ok","artifact_state":{"head":"abc"},"evidence_refs":["e1"]}}
    ;
    var report = try validateText(std.testing.allocator, json, "team-patterns", null);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.valid);
    try std.testing.expect(report.canonical_hash != null);

    const yaml =
        \\skill_decision_receipt:
        \\  receipt_version: SDR-v1
        \\  decision_id: dec-1
        \\  skill: team-patterns
        \\  skill_version: 1
        \\  skill_contract_fingerprint: fp
        \\  trigger_refs: [t1]
        \\  clause_refs: [c1]
        \\  question: choose
        \\  alternatives_considered: [a]
        \\  selected_route: r1
        \\  rejected_routes: [r2]
        \\  expected_outcome: ok
        \\  artifact_state: {}
        \\  evidence_refs: [e1]
    ;
    var yaml_report = try validateText(std.testing.allocator, yaml, "team-patterns", null);
    defer yaml_report.deinit(std.testing.allocator);
    try std.testing.expect(yaml_report.valid);
}

test "SDR validation rejects selected rejected and unknown contract refs" {
    const contract_text =
        \\{"skill_decision_contract":{"contract_version":"SKDC-v1","skill":{"name":"s","kind":"decision","source_fingerprint":"fp"},"triggers":[{"trigger_id":"t1","cue_literals":[],"cue_regexes":[],"exclusions":[]}],"routes":[{"route_id":"r1","aliases":[]}],"clauses":[{"clause_id":"c1","trigger_refs":["t1"],"expected_routes":["r1"],"prohibited_routes":[],"required_artifacts":[],"success_signals":[],"failure_signals":[]}],"instrumentation":{"decision_receipt":"optional"}}}
    ;
    var parsed_contract = try skill_contract.parseText(std.testing.allocator, contract_text);
    defer parsed_contract.deinit();
    const receipt_text =
        \\{"skill_decision_receipt":{"receipt_version":"SDR-v1","decision_id":"dec-1","skill":"s","trigger_refs":["missing"],"clause_refs":["missing"],"selected_route":"r1","rejected_routes":["r1"],"artifact_state":{"head":"abc"}}}
    ;
    var report = try validateText(std.testing.allocator, receipt_text, "s", parsed_contract.contract);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.valid);
    try std.testing.expect(containsCode(report.codes, "selected_route_rejected"));
    try std.testing.expect(containsCode(report.codes, "unknown_trigger_ref"));
    try std.testing.expect(containsCode(report.codes, "unknown_clause_ref"));
}

test "SDR contract-bound validation requires matching embedded fingerprint" {
    const contract_text =
        \\{"skill_decision_contract":{"contract_version":"SKDC-v1","skill":{"name":"s","kind":"decision","source_fingerprint":"fp"},"triggers":[{"trigger_id":"t1","cue_literals":[],"cue_regexes":[],"exclusions":[]}],"routes":[{"route_id":"r1","aliases":[]}],"clauses":[{"clause_id":"c1","trigger_refs":["t1"],"expected_routes":["r1"],"prohibited_routes":[],"required_artifacts":[],"success_signals":[],"failure_signals":[]}],"instrumentation":{"decision_receipt":"optional"}}}
    ;
    var parsed_contract = try skill_contract.parseText(std.testing.allocator, contract_text);
    defer parsed_contract.deinit();
    const contract_fingerprint = try skill_contract.fingerprintContract(std.testing.allocator, parsed_contract.contract);
    defer std.testing.allocator.free(contract_fingerprint);

    const receipt = Receipt{
        .receipt_version = "SDR-v1",
        .decision_id = "dec-1",
        .skill = "s",
        .skill_contract_fingerprint = contract_fingerprint,
        .trigger_refs = &.{"t1"},
        .clause_refs = &.{"c1"},
        .selected_route = "r1",
        .artifact_state_present = true,
        .artifact_state_json = "{}",
    };
    var matching = try validateParsed(std.testing.allocator, receipt, "s", parsed_contract.contract);
    defer matching.deinit(std.testing.allocator);
    try std.testing.expect(matching.valid);

    var missing_receipt = receipt;
    missing_receipt.skill_contract_fingerprint = "";
    var missing = try validateParsed(std.testing.allocator, missing_receipt, "s", parsed_contract.contract);
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(!missing.valid);
    try std.testing.expect(containsCode(missing.codes, "missing_skill_contract_fingerprint"));

    var stale_receipt = receipt;
    stale_receipt.skill_contract_fingerprint = "stale-fingerprint";
    var stale = try validateParsed(std.testing.allocator, stale_receipt, "s", parsed_contract.contract);
    defer stale.deinit(std.testing.allocator);
    try std.testing.expect(!stale.valid);
    try std.testing.expect(containsCode(stale.codes, "skill_contract_fingerprint_mismatch"));
}

test "SDR missing contract preserves receipt without clause validation" {
    const receipt_text =
        \\{"skill_decision_receipt":{"receipt_version":"SDR-v1","decision_id":"dec-1","skill":"s","trigger_refs":["missing"],"clause_refs":["missing"],"selected_route":"r1","rejected_routes":[],"artifact_state":{"head":"abc"}}}
    ;
    var report = try validateText(std.testing.allocator, receipt_text, "s", null);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.valid);
}
