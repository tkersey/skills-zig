const std = @import("std");

pub const version = "DCP-v1";

pub const AnchorName = enum {
    pre_decision,
    post_decision_pre_outcome,
    outcome_aware,

    pub fn name(self: AnchorName) []const u8 {
        return @tagName(self);
    }
};

const anchor_names = [_]AnchorName{ .pre_decision, .post_decision_pre_outcome, .outcome_aware };
const reconstruction_values = [_][]const u8{ "exact", "head_only", "transcript_only", "unavailable" };
const contamination_keys = [_][]const u8{ "injected_skill_blocks", "generated_reports", "current_audit_prompt", "quoted_material" };
const episode_list_keys = [_][]const u8{ "rejected_routes", "explicit_rationale", "explicit_assumptions", "evidence_refs", "tools_and_artifacts", "skills_and_instructions", "outcome_refs" };

pub const ValidationReport = struct {
    valid: bool,
    packet_id: ?[]u8 = null,
    anchors_available: []const []u8 = &.{},
    errors: []const []u8 = &.{},
    warnings: []const []u8 = &.{},

    pub fn deinit(self: *ValidationReport, allocator: std.mem.Allocator) void {
        if (self.packet_id) |value| allocator.free(value);
        for (self.anchors_available) |value| allocator.free(value);
        allocator.free(self.anchors_available);
        for (self.errors) |value| allocator.free(value);
        allocator.free(self.errors);
        for (self.warnings) |value| allocator.free(value);
        allocator.free(self.warnings);
    }
};

pub fn validateText(allocator: std.mem.Allocator, text: []const u8) !ValidationReport {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    return validateValue(allocator, parsed.value);
}

pub fn validateValue(allocator: std.mem.Allocator, value: std.json.Value) !ValidationReport {
    var errors: std.ArrayList([]u8) = .empty;
    defer freeStringList(allocator, &errors);
    var warnings: std.ArrayList([]u8) = .empty;
    defer freeStringList(allocator, &warnings);
    var available: std.ArrayList([]u8) = .empty;
    defer freeStringList(allocator, &available);

    const packet = bodyObject(value) orelse {
        try appendCode(allocator, &errors, "decision_context_packet:must-be-object");
        return finishReport(allocator, &errors, &warnings, &available, null);
    };

    if (!stringFieldEq(packet, "packet_version", version)) try appendCode(allocator, &errors, "packet_version");
    const packet_id = stringField(packet, "packet_id");
    if (packet_id == null or packet_id.?.len == 0) try appendCode(allocator, &errors, "packet_id");

    const source = objectField(packet, "source") orelse blk: {
        try appendCode(allocator, &errors, "source:must-be-object");
        break :blk null;
    };
    if (source) |obj| {
        if (!hasAnyString(obj, &.{ "session_id", "rollout_path", "thread_id" })) {
            try appendCode(allocator, &errors, "source:session-id-rollout-path-or-thread-id-required");
        }
        if (!hasNonEmptyString(obj, "decision_id")) try appendCode(allocator, &errors, "source.decision_id");
    }

    const artifact = objectField(packet, "artifact_state") orelse blk: {
        try appendCode(allocator, &errors, "artifact_state:must-be-object");
        break :blk null;
    };
    if (artifact) |obj| {
        const recon = stringField(obj, "reconstructability");
        if (recon == null or !oneOf(recon.?, &reconstruction_values)) try appendCode(allocator, &errors, "artifact_state.reconstructability");
    }

    const episode = objectField(packet, "episode") orelse blk: {
        try appendCode(allocator, &errors, "episode:must-be-object");
        break :blk null;
    };
    if (episode) |obj| {
        if (!hasNonEmptyString(obj, "question")) try appendCode(allocator, &errors, "episode.question");
        if (!hasNonEmptyString(obj, "selected_route")) try appendCode(allocator, &warnings, "episode.selected_route:unknown");
        for (episode_list_keys) |key| {
            if (!isArrayField(obj, key)) try appendFieldCode(allocator, &errors, key, ":must-be-list");
        }
    }

    var total_turns: i64 = 0;
    var decision_turn_index: i64 = 0;
    var first_outcome_turn_index: ?i64 = null;
    const turns = objectField(packet, "turns") orelse blk: {
        try appendCode(allocator, &errors, "turns:must-be-object");
        break :blk null;
    };
    if (turns) |obj| {
        const total = intField(obj, "total_turns");
        if (total == null or total.? < 1) {
            try appendCode(allocator, &errors, "turns.total_turns");
        } else {
            total_turns = total.?;
        }
        const decision = intField(obj, "decision_turn_index");
        if (decision == null or decision.? < 1 or (total_turns > 0 and decision.? > total_turns)) {
            try appendCode(allocator, &errors, "turns.decision_turn_index");
        } else {
            decision_turn_index = decision.?;
        }
        first_outcome_turn_index = intField(obj, "first_outcome_turn_index");
        if (first_outcome_turn_index) |outcome| {
            if (decision_turn_index > 0 and (outcome <= decision_turn_index or (total_turns > 0 and outcome > total_turns))) {
                try appendCode(allocator, &errors, "turns.first_outcome_turn_index");
            }
        }
        if (!hasNonEmptyString(obj, "source_turn_digest")) try appendCode(allocator, &errors, "turns.source_turn_digest");
    }

    const anchors = objectField(packet, "anchors") orelse blk: {
        try appendCode(allocator, &errors, "anchors:must-be-object");
        break :blk null;
    };
    if (anchors) |obj| {
        for (anchor_names) |anchor_name| {
            const name = anchor_name.name();
            const anchor = objectField(obj, name) orelse {
                try appendFieldCode(allocator, &errors, name, ":must-be-object");
                continue;
            };
            const is_available = boolField(anchor, "available") orelse {
                try appendAnchorCode(allocator, &errors, name, ".available");
                continue;
            };
            if (is_available) {
                try available.append(allocator, try allocator.dupe(u8, name));
                const keep = intField(anchor, "keep_through_turn_index");
                const drop = intField(anchor, "drop_last_n_turns");
                if (keep == null or keep.? < 0 or (total_turns > 0 and keep.? > total_turns)) try appendAnchorCode(allocator, &errors, name, ".keep_through_turn_index");
                if (drop == null or drop.? < 0) try appendAnchorCode(allocator, &errors, name, ".drop_last_n_turns");
                if (keep != null and drop != null and total_turns > 0 and keep.? + drop.? != total_turns) {
                    try appendAnchorCode(allocator, &errors, name, ":keep-plus-drop-must-equal-total");
                }
                if (!hasNonEmptyString(anchor, "anchor_digest")) try appendAnchorCode(allocator, &errors, name, ".anchor_digest");
                if (anchor_name == .pre_decision and decision_turn_index > 0 and keep != null and keep.? >= decision_turn_index) {
                    try appendCode(allocator, &errors, "anchors.pre_decision:must-end-before-decision");
                }
                if (anchor_name == .post_decision_pre_outcome and decision_turn_index > 0 and keep != null) {
                    if (keep.? < decision_turn_index) try appendCode(allocator, &errors, "anchors.post_decision_pre_outcome:must-include-decision");
                    if (first_outcome_turn_index) |outcome| {
                        if (keep.? >= outcome) try appendCode(allocator, &errors, "anchors.post_decision_pre_outcome:must-precede-outcome");
                    }
                }
                if (anchor_name == .outcome_aware and total_turns > 0 and keep != null and keep.? != total_turns) {
                    try appendCode(allocator, &warnings, "anchors.outcome_aware:does-not-include-full-history");
                }
            } else if (hasNonEmptyString(anchor, "anchor_digest")) {
                try appendAnchorCode(allocator, &warnings, name, ":unavailable-with-digest");
            }
        }
    }

    const contamination = objectField(packet, "contamination") orelse blk: {
        try appendCode(allocator, &errors, "contamination:must-be-object");
        break :blk null;
    };
    if (contamination) |obj| {
        for (contamination_keys) |key| {
            if (boolField(obj, key) == null) try appendFieldCode(allocator, &errors, "contamination.", key);
        }
    }
    if (!isArrayField(packet, "limitations")) try appendCode(allocator, &errors, "limitations:must-be-list");

    return finishReport(allocator, &errors, &warnings, &available, packet_id);
}

pub fn packetIdForCanonicalBody(allocator: std.mem.Allocator, body_without_packet_id: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body_without_packet_id, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "DCP-{s}", .{hex});
}

fn finishReport(
    allocator: std.mem.Allocator,
    errors: *std.ArrayList([]u8),
    warnings: *std.ArrayList([]u8),
    available: *std.ArrayList([]u8),
    packet_id: ?[]const u8,
) !ValidationReport {
    const err_owned = try errors.toOwnedSlice(allocator);
    errors.* = .empty;
    errdefer {
        for (err_owned) |value| allocator.free(value);
        allocator.free(err_owned);
    }
    const warn_owned = try warnings.toOwnedSlice(allocator);
    warnings.* = .empty;
    errdefer {
        for (warn_owned) |value| allocator.free(value);
        allocator.free(warn_owned);
    }
    const avail_owned = try available.toOwnedSlice(allocator);
    available.* = .empty;
    errdefer {
        for (avail_owned) |value| allocator.free(value);
        allocator.free(avail_owned);
    }
    return .{
        .valid = err_owned.len == 0,
        .packet_id = if (packet_id) |id| try allocator.dupe(u8, id) else null,
        .anchors_available = avail_owned,
        .errors = err_owned,
        .warnings = warn_owned,
    };
}

fn bodyObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| blk: {
            if (obj.get("decision_context_packet")) |wrapped| {
                break :blk switch (wrapped) {
                    .object => |inner| inner,
                    else => null,
                };
            }
            break :blk obj;
        },
        else => null,
    };
}

fn objectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .object => |inner| inner,
        else => null,
    };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn stringFieldEq(obj: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const text = stringField(obj, key) orelse return false;
    return std.mem.eql(u8, text, expected);
}

fn hasNonEmptyString(obj: std.json.ObjectMap, key: []const u8) bool {
    const text = stringField(obj, key) orelse return false;
    return text.len > 0;
}

fn hasAnyString(obj: std.json.ObjectMap, keys: []const []const u8) bool {
    for (keys) |key| {
        if (hasNonEmptyString(obj, key)) return true;
    }
    return false;
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn isArrayField(obj: std.json.ObjectMap, key: []const u8) bool {
    const value = obj.get(key) orelse return false;
    return switch (value) {
        .array => true,
        else => false,
    };
}

fn oneOf(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn appendCode(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), code: []const u8) !void {
    try list.append(allocator, try allocator.dupe(u8, code));
}

fn appendFieldCode(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), field: []const u8, suffix: []const u8) !void {
    const code = try std.fmt.allocPrint(allocator, "{s}{s}", .{ field, suffix });
    try list.append(allocator, code);
}

fn appendAnchorCode(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), anchor: []const u8, suffix: []const u8) !void {
    const code = try std.fmt.allocPrint(allocator, "anchors.{s}{s}", .{ anchor, suffix });
    try list.append(allocator, code);
}

fn freeStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

test "DCP validation catches bad anchor arithmetic" {
    const text =
        \\{"decision_context_packet":{
        \\"packet_version":"DCP-v1","packet_id":"DCP-test",
        \\"source":{"session_id":"s","decision_id":"d"},
        \\"artifact_state":{"reconstructability":"transcript_only"},
        \\"episode":{"question":"q","selected_route":"r","rejected_routes":[],"explicit_rationale":[],"explicit_assumptions":[],"evidence_refs":[],"tools_and_artifacts":[],"skills_and_instructions":[],"outcome_refs":[]},
        \\"turns":{"total_turns":3,"decision_turn_index":2,"decision_turn_id":"t2","source_turn_digest":"sha256:x"},
        \\"anchors":{"pre_decision":{"available":true,"keep_through_turn_index":2,"drop_last_n_turns":1,"anchor_digest":"sha256:a"},"post_decision_pre_outcome":{"available":true,"keep_through_turn_index":2,"drop_last_n_turns":1,"anchor_digest":"sha256:b"},"outcome_aware":{"available":true,"keep_through_turn_index":3,"drop_last_n_turns":0,"anchor_digest":"sha256:c"}},
        \\"contamination":{"injected_skill_blocks":false,"generated_reports":false,"current_audit_prompt":false,"quoted_material":false},
        \\"limitations":[]}}
    ;
    var report = try validateText(std.testing.allocator, text);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.valid);
    try std.testing.expect(containsCode(report.errors, "anchors.pre_decision:must-end-before-decision"));
}

fn containsCode(codes: []const []u8, needle: []const u8) bool {
    for (codes) |code| {
        if (std.mem.eql(u8, code, needle)) return true;
    }
    return false;
}
