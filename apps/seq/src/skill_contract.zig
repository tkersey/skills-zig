const std = @import("std");

pub const Contract = struct {
    contract_version: []const u8 = "",
    skill_name: []const u8 = "",
    skill_kind: []const u8 = "",
    source_fingerprint: ?[]const u8 = null,
    triggers: []Trigger = &.{},
    routes: []Route = &.{},
    clauses: []Clause = &.{},
    receipt_requirement: []const u8 = "",
    instrumentation_rationale: []const u8 = "",
};

pub const Trigger = struct {
    trigger_id: []const u8 = "",
    description: []const u8 = "",
    cue_literals: []const []const u8 = &.{},
    cue_regexes: []const []const u8 = &.{},
    exclusions: []const []const u8 = &.{},
};

pub const Route = struct {
    route_id: []const u8 = "",
    description: []const u8 = "",
    aliases: []const []const u8 = &.{},
    terminal: bool = false,
};

pub const Clause = struct {
    clause_id: []const u8 = "",
    trigger_refs: []const []const u8 = &.{},
    expected_routes: []const []const u8 = &.{},
    prohibited_routes: []const []const u8 = &.{},
    required_artifacts: []const []const u8 = &.{},
    success_signals: []const []const u8 = &.{},
    failure_signals: []const []const u8 = &.{},
    rationale: []const u8 = "",
};

pub const ParsedContract = struct {
    arena: std.heap.ArenaAllocator,
    contract: Contract,

    pub fn deinit(self: *ParsedContract) void {
        self.arena.deinit();
    }
};

pub const ValidationReport = struct {
    valid: bool,
    codes: []const []const u8,
    fingerprint: ?[]const u8,

    pub fn deinit(self: ValidationReport, allocator: std.mem.Allocator) void {
        allocator.free(self.codes);
        if (self.fingerprint) |fp| allocator.free(fp);
    }
};

pub fn parseText(allocator: std.mem.Allocator, text: []const u8) !ParsedContract {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidSpec;
    if (trimmed[0] == '{') return parseJsonText(allocator, trimmed);
    return parseYamlText(allocator, trimmed);
}

pub fn validateText(allocator: std.mem.Allocator, text: []const u8) !ValidationReport {
    var parsed = try parseText(allocator, text);
    defer parsed.deinit();
    return validateParsed(allocator, parsed.contract);
}

pub fn validateParsed(allocator: std.mem.Allocator, contract: Contract) !ValidationReport {
    var codes: std.ArrayList([]const u8) = .empty;
    defer codes.deinit(allocator);

    if (!std.mem.eql(u8, contract.contract_version, "SKDC-v1")) try codes.append(allocator, "invalid_contract_version");
    if (contract.skill_name.len == 0) try codes.append(allocator, "missing_skill_name");
    if (!isValidSkillKind(contract.skill_kind)) try codes.append(allocator, "invalid_skill_kind");
    if (contract.source_fingerprint == null or contract.source_fingerprint.?.len == 0) try codes.append(allocator, "source_fingerprint_absent");

    var trigger_ids = std.StringHashMap(void).init(allocator);
    defer trigger_ids.deinit();
    for (contract.triggers) |trigger| {
        if (trigger.trigger_id.len == 0) {
            try codes.append(allocator, "missing_trigger_id");
        } else if (trigger_ids.contains(trigger.trigger_id)) {
            try codes.append(allocator, "duplicate_trigger_id");
        } else {
            try trigger_ids.put(trigger.trigger_id, {});
        }
        for (trigger.cue_regexes) |pattern| {
            if (!isSupportedSeqRegex(pattern)) try codes.append(allocator, "invalid_regex");
        }
    }

    var route_ids = std.StringHashMap(void).init(allocator);
    defer route_ids.deinit();
    var aliases = std.StringHashMap([]const u8).init(allocator);
    defer aliases.deinit();
    for (contract.routes) |route| {
        if (route.route_id.len == 0) {
            try codes.append(allocator, "missing_route_id");
        } else if (route_ids.contains(route.route_id)) {
            try codes.append(allocator, "duplicate_route_id");
        } else {
            try route_ids.put(route.route_id, {});
        }
        for (route.aliases) |alias| {
            if (aliases.get(alias)) |owner| {
                if (!std.mem.eql(u8, owner, route.route_id)) try codes.append(allocator, "route_alias_collision");
            } else {
                try aliases.put(alias, route.route_id);
            }
        }
    }

    var clause_ids = std.StringHashMap(void).init(allocator);
    defer clause_ids.deinit();
    for (contract.clauses) |clause| {
        if (clause.clause_id.len == 0) {
            try codes.append(allocator, "missing_clause_id");
        } else if (clause_ids.contains(clause.clause_id)) {
            try codes.append(allocator, "duplicate_clause_id");
        } else {
            try clause_ids.put(clause.clause_id, {});
        }
        for (clause.trigger_refs) |id| if (!trigger_ids.contains(id)) try codes.append(allocator, "unknown_trigger_ref");
        for (clause.expected_routes) |id| if (!route_ids.contains(id)) try codes.append(allocator, "unknown_expected_route_ref");
        for (clause.prohibited_routes) |id| if (!route_ids.contains(id)) try codes.append(allocator, "unknown_prohibited_route_ref");
        for (clause.expected_routes) |expected| {
            for (clause.prohibited_routes) |prohibited| {
                if (std.mem.eql(u8, expected, prohibited)) try codes.append(allocator, "expected_prohibited_route_overlap");
            }
        }
    }

    if ((std.mem.eql(u8, contract.skill_kind, "decision") or std.mem.eql(u8, contract.skill_kind, "mixed")) and
        (contract.routes.len == 0 or contract.clauses.len == 0))
    {
        try codes.append(allocator, "decision_skill_missing_routes_or_clauses");
    }
    if (!isValidReceiptRequirement(contract.receipt_requirement)) try codes.append(allocator, "invalid_receipt_requirement");

    const valid = onlyWarnings(codes.items);
    const fingerprint = if (valid) try fingerprintContract(allocator, contract) else null;
    return .{
        .valid = valid,
        .codes = try allocator.dupe([]const u8, codes.items),
        .fingerprint = fingerprint,
    };
}

pub fn fingerprintText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var parsed = try parseText(allocator, text);
    defer parsed.deinit();
    return fingerprintContract(allocator, parsed.contract);
}

pub fn fingerprintContract(allocator: std.mem.Allocator, contract: Contract) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    try writeCanonicalContract(&writer_alloc.writer, contract);
    const canonical = try writer_alloc.toOwnedSlice();
    defer allocator.free(canonical);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, hex[0..]);
}

fn parseJsonText(allocator: std.mem.Allocator, text: []const u8) !ParsedContract {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parsed_json = try std.json.parseFromSlice(std.json.Value, arena.allocator(), text, .{});
    defer parsed_json.deinit();
    const root = objectValue(parsed_json.value) orelse return error.InvalidSpec;
    const contract_value = root.get("skill_decision_contract") orelse return error.InvalidSpec;
    const contract = try parseContractValue(arena.allocator(), contract_value);
    return .{ .arena = arena, .contract = contract };
}

fn parseContractValue(allocator: std.mem.Allocator, value: std.json.Value) !Contract {
    const obj = objectValue(value) orelse return error.InvalidSpec;
    var contract = Contract{};
    contract.contract_version = try dupStringField(allocator, obj, "contract_version", "");

    if (obj.get("skill")) |skill_value| {
        const skill = objectValue(skill_value) orelse return error.InvalidSpec;
        contract.skill_name = try dupStringField(allocator, skill, "name", "");
        contract.skill_kind = try dupStringField(allocator, skill, "kind", "");
        contract.source_fingerprint = try dupOptionalStringField(allocator, skill, "source_fingerprint");
    }
    contract.triggers = try parseTriggersValue(allocator, obj.get("triggers"));
    contract.routes = try parseRoutesValue(allocator, obj.get("routes"));
    contract.clauses = try parseClausesValue(allocator, obj.get("clauses"));
    if (obj.get("instrumentation")) |inst_value| {
        const inst = objectValue(inst_value) orelse return error.InvalidSpec;
        if (inst.get("decision_receipt")) |receipt_value| {
            contract.receipt_requirement = try dupValueString(allocator, receipt_value, "");
        }
        contract.instrumentation_rationale = try dupStringField(allocator, inst, "rationale", "");
    }
    return contract;
}

fn parseTriggersValue(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]Trigger {
    const value = value_opt orelse return &.{};
    const arr = arrayValue(value) orelse return error.InvalidSpec;
    var out: std.ArrayList(Trigger) = .empty;
    for (arr.items) |item| {
        const obj = objectValue(item) orelse return error.InvalidSpec;
        try out.append(allocator, .{
            .trigger_id = try dupStringField(allocator, obj, "trigger_id", ""),
            .description = try dupStringField(allocator, obj, "description", ""),
            .cue_literals = try dupStringArrayField(allocator, obj, "cue_literals"),
            .cue_regexes = try dupStringArrayField(allocator, obj, "cue_regexes"),
            .exclusions = try dupStringArrayField(allocator, obj, "exclusions"),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseRoutesValue(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]Route {
    const value = value_opt orelse return &.{};
    const arr = arrayValue(value) orelse return error.InvalidSpec;
    var out: std.ArrayList(Route) = .empty;
    for (arr.items) |item| {
        const obj = objectValue(item) orelse return error.InvalidSpec;
        try out.append(allocator, .{
            .route_id = try dupStringField(allocator, obj, "route_id", ""),
            .description = try dupStringField(allocator, obj, "description", ""),
            .aliases = try dupStringArrayField(allocator, obj, "aliases"),
            .terminal = boolField(obj, "terminal", false),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseClausesValue(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]Clause {
    const value = value_opt orelse return &.{};
    const arr = arrayValue(value) orelse return error.InvalidSpec;
    var out: std.ArrayList(Clause) = .empty;
    for (arr.items) |item| {
        const obj = objectValue(item) orelse return error.InvalidSpec;
        try out.append(allocator, .{
            .clause_id = try dupStringField(allocator, obj, "clause_id", ""),
            .trigger_refs = try dupStringArrayField(allocator, obj, "trigger_refs"),
            .expected_routes = try dupStringArrayField(allocator, obj, "expected_routes"),
            .prohibited_routes = try dupStringArrayField(allocator, obj, "prohibited_routes"),
            .required_artifacts = try dupStringArrayField(allocator, obj, "required_artifacts"),
            .success_signals = try dupStringArrayField(allocator, obj, "success_signals"),
            .failure_signals = try dupStringArrayField(allocator, obj, "failure_signals"),
            .rationale = try dupStringField(allocator, obj, "rationale", ""),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseYamlText(allocator: std.mem.Allocator, text: []const u8) !ParsedContract {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var contract = Contract{};
    var triggers: std.ArrayList(Trigger) = .empty;
    var routes: std.ArrayList(Route) = .empty;
    var clauses: std.ArrayList(Clause) = .empty;
    var section: enum { none, skill, triggers, routes, clauses, instrumentation } = .none;

    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw_line| {
        const no_cr = std.mem.trim(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, no_cr, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const indent = countIndent(no_cr);
        if (indent == 0) {
            if (!std.mem.eql(u8, trimmed, "skill_decision_contract:")) return error.InvalidSpec;
            continue;
        }
        if (indent == 2) {
            const kv = splitYamlKeyValue(trimmed) orelse return error.InvalidSpec;
            if (std.mem.eql(u8, kv.key, "contract_version")) {
                contract.contract_version = try dupYamlScalar(aa, kv.value);
                section = .none;
            } else if (std.mem.eql(u8, kv.key, "skill")) {
                section = .skill;
            } else if (std.mem.eql(u8, kv.key, "triggers")) {
                section = .triggers;
            } else if (std.mem.eql(u8, kv.key, "routes")) {
                section = .routes;
            } else if (std.mem.eql(u8, kv.key, "clauses")) {
                section = .clauses;
            } else if (std.mem.eql(u8, kv.key, "instrumentation")) {
                section = .instrumentation;
            }
            continue;
        }
        switch (section) {
            .skill => {
                if (indent != 4) return error.InvalidSpec;
                const kv = splitYamlKeyValue(trimmed) orelse return error.InvalidSpec;
                if (std.mem.eql(u8, kv.key, "name")) contract.skill_name = try dupYamlScalar(aa, kv.value) else if (std.mem.eql(u8, kv.key, "kind")) contract.skill_kind = try dupYamlScalar(aa, kv.value) else if (std.mem.eql(u8, kv.key, "source_fingerprint")) contract.source_fingerprint = try dupYamlOptionalScalar(aa, kv.value);
            },
            .instrumentation => {
                if (indent != 4) return error.InvalidSpec;
                const kv = splitYamlKeyValue(trimmed) orelse return error.InvalidSpec;
                if (std.mem.eql(u8, kv.key, "decision_receipt")) contract.receipt_requirement = try dupYamlScalar(aa, kv.value) else if (std.mem.eql(u8, kv.key, "rationale")) contract.instrumentation_rationale = try dupYamlScalar(aa, kv.value);
            },
            .triggers => try parseYamlTriggerLine(aa, &triggers, indent, trimmed),
            .routes => try parseYamlRouteLine(aa, &routes, indent, trimmed),
            .clauses => try parseYamlClauseLine(aa, &clauses, indent, trimmed),
            .none => return error.InvalidSpec,
        }
    }
    contract.triggers = try triggers.toOwnedSlice(aa);
    contract.routes = try routes.toOwnedSlice(aa);
    contract.clauses = try clauses.toOwnedSlice(aa);
    return .{ .arena = arena, .contract = contract };
}

fn parseYamlTriggerLine(allocator: std.mem.Allocator, out: *std.ArrayList(Trigger), indent: usize, trimmed: []const u8) !void {
    if (indent == 4 and std.mem.startsWith(u8, trimmed, "- ")) {
        var trigger = Trigger{};
        const kv = splitYamlKeyValue(trimmed[2..]) orelse return error.InvalidSpec;
        if (!std.mem.eql(u8, kv.key, "trigger_id")) return error.InvalidSpec;
        trigger.trigger_id = try dupYamlScalar(allocator, kv.value);
        try out.append(allocator, trigger);
        return;
    }
    if (indent != 6 or out.items.len == 0) return error.InvalidSpec;
    const kv = splitYamlKeyValue(trimmed) orelse return error.InvalidSpec;
    var item = &out.items[out.items.len - 1];
    if (std.mem.eql(u8, kv.key, "description")) item.description = try dupYamlScalar(allocator, kv.value) else if (std.mem.eql(u8, kv.key, "cue_literals")) item.cue_literals = try parseYamlInlineList(allocator, kv.value) else if (std.mem.eql(u8, kv.key, "cue_regexes")) item.cue_regexes = try parseYamlInlineList(allocator, kv.value) else if (std.mem.eql(u8, kv.key, "exclusions")) item.exclusions = try parseYamlInlineList(allocator, kv.value);
}

fn parseYamlRouteLine(allocator: std.mem.Allocator, out: *std.ArrayList(Route), indent: usize, trimmed: []const u8) !void {
    if (indent == 4 and std.mem.startsWith(u8, trimmed, "- ")) {
        var route = Route{};
        const kv = splitYamlKeyValue(trimmed[2..]) orelse return error.InvalidSpec;
        if (!std.mem.eql(u8, kv.key, "route_id")) return error.InvalidSpec;
        route.route_id = try dupYamlScalar(allocator, kv.value);
        try out.append(allocator, route);
        return;
    }
    if (indent != 6 or out.items.len == 0) return error.InvalidSpec;
    const kv = splitYamlKeyValue(trimmed) orelse return error.InvalidSpec;
    var item = &out.items[out.items.len - 1];
    if (std.mem.eql(u8, kv.key, "description")) item.description = try dupYamlScalar(allocator, kv.value) else if (std.mem.eql(u8, kv.key, "aliases")) item.aliases = try parseYamlInlineList(allocator, kv.value) else if (std.mem.eql(u8, kv.key, "terminal")) item.terminal = parseYamlBool(kv.value);
}

fn parseYamlClauseLine(allocator: std.mem.Allocator, out: *std.ArrayList(Clause), indent: usize, trimmed: []const u8) !void {
    if (indent == 4 and std.mem.startsWith(u8, trimmed, "- ")) {
        var clause = Clause{};
        const kv = splitYamlKeyValue(trimmed[2..]) orelse return error.InvalidSpec;
        if (!std.mem.eql(u8, kv.key, "clause_id")) return error.InvalidSpec;
        clause.clause_id = try dupYamlScalar(allocator, kv.value);
        try out.append(allocator, clause);
        return;
    }
    if (indent != 6 or out.items.len == 0) return error.InvalidSpec;
    const kv = splitYamlKeyValue(trimmed) orelse return error.InvalidSpec;
    var item = &out.items[out.items.len - 1];
    if (std.mem.eql(u8, kv.key, "trigger_refs")) item.trigger_refs = try parseYamlInlineList(allocator, kv.value) else if (std.mem.eql(u8, kv.key, "expected_routes")) item.expected_routes = try parseYamlInlineList(allocator, kv.value) else if (std.mem.eql(u8, kv.key, "prohibited_routes")) item.prohibited_routes = try parseYamlInlineList(allocator, kv.value) else if (std.mem.eql(u8, kv.key, "required_artifacts")) item.required_artifacts = try parseYamlInlineList(allocator, kv.value) else if (std.mem.eql(u8, kv.key, "success_signals")) item.success_signals = try parseYamlInlineList(allocator, kv.value) else if (std.mem.eql(u8, kv.key, "failure_signals")) item.failure_signals = try parseYamlInlineList(allocator, kv.value) else if (std.mem.eql(u8, kv.key, "rationale")) item.rationale = try dupYamlScalar(allocator, kv.value);
}

fn writeCanonicalContract(writer: anytype, contract: Contract) !void {
    try writer.writeAll("{\"skill_decision_contract\":{\"clauses\":[");
    for (contract.clauses, 0..) |clause, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"clause_id\":");
        try writeJsonString(writer, clause.clause_id);
        try writer.writeAll(",\"expected_routes\":");
        try writeJsonStringArray(writer, clause.expected_routes);
        try writer.writeAll(",\"failure_signals\":");
        try writeJsonStringArray(writer, clause.failure_signals);
        try writer.writeAll(",\"prohibited_routes\":");
        try writeJsonStringArray(writer, clause.prohibited_routes);
        try writer.writeAll(",\"rationale\":");
        try writeJsonString(writer, clause.rationale);
        try writer.writeAll(",\"required_artifacts\":");
        try writeJsonStringArray(writer, clause.required_artifacts);
        try writer.writeAll(",\"success_signals\":");
        try writeJsonStringArray(writer, clause.success_signals);
        try writer.writeAll(",\"trigger_refs\":");
        try writeJsonStringArray(writer, clause.trigger_refs);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"contract_version\":");
    try writeJsonString(writer, contract.contract_version);
    try writer.writeAll(",\"instrumentation\":{\"decision_receipt\":");
    try writeJsonString(writer, contract.receipt_requirement);
    try writer.writeAll(",\"rationale\":");
    try writeJsonString(writer, contract.instrumentation_rationale);
    try writer.writeAll("},\"routes\":[");
    for (contract.routes, 0..) |route, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"aliases\":");
        try writeJsonStringArray(writer, route.aliases);
        try writer.writeAll(",\"description\":");
        try writeJsonString(writer, route.description);
        try writer.writeAll(",\"route_id\":");
        try writeJsonString(writer, route.route_id);
        try writer.writeAll(",\"terminal\":");
        try writer.writeAll(if (route.terminal) "true" else "false");
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"skill\":{\"kind\":");
    try writeJsonString(writer, contract.skill_kind);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, contract.skill_name);
    try writer.writeAll(",\"source_fingerprint\":");
    if (contract.source_fingerprint) |fp| try writeJsonString(writer, fp) else try writer.writeAll("null");
    try writer.writeAll("},\"triggers\":[");
    for (contract.triggers, 0..) |trigger, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"cue_literals\":");
        try writeJsonStringArray(writer, trigger.cue_literals);
        try writer.writeAll(",\"cue_regexes\":");
        try writeJsonStringArray(writer, trigger.cue_regexes);
        try writer.writeAll(",\"description\":");
        try writeJsonString(writer, trigger.description);
        try writer.writeAll(",\"exclusions\":");
        try writeJsonStringArray(writer, trigger.exclusions);
        try writer.writeAll(",\"trigger_id\":");
        try writeJsonString(writer, trigger.trigger_id);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}}");
}

fn objectValue(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn arrayValue(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |arr| arr,
        else => null,
    };
}

fn dupStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return allocator.dupe(u8, default);
    return dupValueString(allocator, value, default);
}

fn dupOptionalStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| try allocator.dupe(u8, text),
        else => error.InvalidSpec,
    };
}

fn dupValueString(allocator: std.mem.Allocator, value: std.json.Value, default: []const u8) ![]const u8 {
    return switch (value) {
        .null => try allocator.dupe(u8, default),
        .string => |text| try allocator.dupe(u8, text),
        else => error.InvalidSpec,
    };
}

fn dupStringArrayField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = obj.get(key) orelse return &.{};
    const arr = arrayValue(value) orelse return error.InvalidSpec;
    var out: std.ArrayList([]const u8) = .empty;
    for (arr.items) |item| {
        if (item != .string) return error.InvalidSpec;
        try out.append(allocator, try allocator.dupe(u8, item.string));
    }
    return out.toOwnedSlice(allocator);
}

fn boolField(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = obj.get(key) orelse return default;
    return switch (value) {
        .bool => |b| b,
        else => default,
    };
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

fn dupYamlOptionalScalar(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const scalar = std.mem.trim(u8, raw, " \t");
    if (scalar.len == 0 or std.mem.eql(u8, scalar, "null")) return null;
    return try dupYamlScalar(allocator, scalar);
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

fn parseYamlBool(raw: []const u8) bool {
    const text = std.mem.trim(u8, raw, " \t");
    return std.mem.eql(u8, text, "yes") or std.mem.eql(u8, text, "true");
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

fn isValidSkillKind(text: []const u8) bool {
    return std.mem.eql(u8, text, "decision") or
        std.mem.eql(u8, text, "execution") or
        std.mem.eql(u8, text, "evidence") or
        std.mem.eql(u8, text, "orchestration") or
        std.mem.eql(u8, text, "mixed");
}

fn isValidReceiptRequirement(text: []const u8) bool {
    return text.len == 0 or
        std.mem.eql(u8, text, "required") or
        std.mem.eql(u8, text, "optional") or
        std.mem.eql(u8, text, "not-needed");
}

fn isSupportedSeqRegex(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    for (pattern) |byte| switch (byte) {
        '\\', '.', '*', '+', '?', '[', ']', '(', ')', '{', '}' => return false,
        else => {},
    };
    return true;
}

fn onlyWarnings(codes: []const []const u8) bool {
    for (codes) |code| {
        if (!std.mem.eql(u8, code, "source_fingerprint_absent") and
            !std.mem.eql(u8, code, "route_alias_collision"))
        {
            return false;
        }
    }
    return true;
}

pub fn containsCode(codes: []const []const u8, needle: []const u8) bool {
    for (codes) |code| if (std.mem.eql(u8, code, needle)) return true;
    return false;
}

test "valid SKDC JSON and YAML validate with stable fingerprint" {
    const json =
        \\{"skill_decision_contract":{"contract_version":"SKDC-v1","skill":{"name":"team-patterns","kind":"decision","source_fingerprint":"abc"},"triggers":[{"trigger_id":"t1","description":"cue","cue_literals":["review"],"cue_regexes":["^fix$"],"exclusions":[]}],"routes":[{"route_id":"r1","description":"route","aliases":["route one"],"terminal":true}],"clauses":[{"clause_id":"c1","trigger_refs":["t1"],"expected_routes":["r1"],"prohibited_routes":[],"required_artifacts":["test"],"success_signals":[],"failure_signals":[],"rationale":"because"}],"instrumentation":{"decision_receipt":"optional","rationale":"record"}}}
    ;
    var report = try validateText(std.testing.allocator, json);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.valid);
    try std.testing.expect(report.fingerprint != null);

    const reordered =
        \\{"skill_decision_contract":{"instrumentation":{"rationale":"record","decision_receipt":"optional"},"clauses":[{"rationale":"because","success_signals":[],"required_artifacts":["test"],"prohibited_routes":[],"failure_signals":[],"expected_routes":["r1"],"trigger_refs":["t1"],"clause_id":"c1"}],"routes":[{"terminal":true,"route_id":"r1","description":"route","aliases":["route one"]}],"triggers":[{"trigger_id":"t1","exclusions":[],"description":"cue","cue_regexes":["^fix$"],"cue_literals":["review"]}],"skill":{"source_fingerprint":"abc","kind":"decision","name":"team-patterns"},"contract_version":"SKDC-v1"}}
    ;
    const fp1 = try fingerprintText(std.testing.allocator, json);
    defer std.testing.allocator.free(fp1);
    const fp2 = try fingerprintText(std.testing.allocator, reordered);
    defer std.testing.allocator.free(fp2);
    try std.testing.expect(std.mem.eql(u8, fp1, fp2));

    const yaml =
        \\skill_decision_contract:
        \\  contract_version: SKDC-v1
        \\  skill:
        \\    name: team-patterns
        \\    kind: decision
        \\    source_fingerprint: abc
        \\  triggers:
        \\    - trigger_id: t1
        \\      description: cue
        \\      cue_literals: [review]
        \\      cue_regexes: [^fix$]
        \\      exclusions: []
        \\  routes:
        \\    - route_id: r1
        \\      description: route
        \\      aliases: [route one]
        \\      terminal: yes
        \\  clauses:
        \\    - clause_id: c1
        \\      trigger_refs: [t1]
        \\      expected_routes: [r1]
        \\      prohibited_routes: []
        \\      required_artifacts: [test]
        \\      success_signals: []
        \\      failure_signals: []
        \\      rationale: because
        \\  instrumentation:
        \\    decision_receipt: optional
        \\    rationale: record
    ;
    var yaml_report = try validateText(std.testing.allocator, yaml);
    defer yaml_report.deinit(std.testing.allocator);
    try std.testing.expect(yaml_report.valid);
}

test "SKDC YAML identity excludes unknown nested route fields" {
    const yaml =
        \\skill_decision_contract:
        \\  contract_version: SKDC-v1
        \\  skill:
        \\    name: universalist
        \\    kind: decision
        \\    source_fingerprint: fixture
        \\  triggers:
        \\    - trigger_id: t1
        \\  routes:
        \\    - route_id: r1
        \\      route_id: r-stray
        \\    - route_id: r2
        \\  clauses:
        \\    - clause_id: c1
        \\      trigger_refs: [t1]
        \\      expected_routes: [r1]
        \\      prohibited_routes: [r2]
        \\  instrumentation:
        \\    decision_receipt: required
    ;
    var parsed = try parseText(std.testing.allocator, yaml);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.contract.routes.len);
    try std.testing.expectEqualStrings("r1", parsed.contract.routes[0].route_id);
    try std.testing.expectEqualStrings("r2", parsed.contract.routes[1].route_id);
}

test "SKDC validation catches duplicate ids refs overlap and regex" {
    const bad =
        \\{"skill_decision_contract":{"contract_version":"SKDC-v1","skill":{"name":"s","kind":"decision"},"triggers":[{"trigger_id":"t1","cue_regexes":["a.*"],"cue_literals":[],"exclusions":[]},{"trigger_id":"t1","cue_regexes":[],"cue_literals":[],"exclusions":[]}],"routes":[{"route_id":"r1","aliases":["same"]},{"route_id":"r2","aliases":["same"]}],"clauses":[{"clause_id":"c1","trigger_refs":["missing"],"expected_routes":["r1"],"prohibited_routes":["r1","missing"],"required_artifacts":[],"success_signals":[],"failure_signals":[]}],"instrumentation":{"decision_receipt":"optional"}}}
    ;
    var report = try validateText(std.testing.allocator, bad);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.valid);
    try std.testing.expect(containsCode(report.codes, "duplicate_trigger_id"));
    try std.testing.expect(containsCode(report.codes, "unknown_trigger_ref"));
    try std.testing.expect(containsCode(report.codes, "unknown_prohibited_route_ref"));
    try std.testing.expect(containsCode(report.codes, "expected_prohibited_route_overlap"));
    try std.testing.expect(containsCode(report.codes, "invalid_regex"));
    try std.testing.expect(containsCode(report.codes, "source_fingerprint_absent"));
    try std.testing.expect(containsCode(report.codes, "route_alias_collision"));
}

test "SKDC array order affects fingerprint" {
    const one =
        \\{"skill_decision_contract":{"contract_version":"SKDC-v1","skill":{"name":"s","kind":"decision","source_fingerprint":"fp"},"triggers":[{"trigger_id":"t1","cue_literals":["a","b"],"cue_regexes":[],"exclusions":[]}],"routes":[{"route_id":"r1","aliases":[]}],"clauses":[{"clause_id":"c1","trigger_refs":["t1"],"expected_routes":["r1"],"prohibited_routes":[],"required_artifacts":[],"success_signals":[],"failure_signals":[]}],"instrumentation":{"decision_receipt":"optional"}}}
    ;
    const two =
        \\{"skill_decision_contract":{"contract_version":"SKDC-v1","skill":{"name":"s","kind":"decision","source_fingerprint":"fp"},"triggers":[{"trigger_id":"t1","cue_literals":["b","a"],"cue_regexes":[],"exclusions":[]}],"routes":[{"route_id":"r1","aliases":[]}],"clauses":[{"clause_id":"c1","trigger_refs":["t1"],"expected_routes":["r1"],"prohibited_routes":[],"required_artifacts":[],"success_signals":[],"failure_signals":[]}],"instrumentation":{"decision_receipt":"optional"}}}
    ;
    const fp1 = try fingerprintText(std.testing.allocator, one);
    defer std.testing.allocator.free(fp1);
    const fp2 = try fingerprintText(std.testing.allocator, two);
    defer std.testing.allocator.free(fp2);
    try std.testing.expect(!std.mem.eql(u8, fp1, fp2));
}
