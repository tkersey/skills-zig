const std = @import("std");

pub const version = "DCP-v2";

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

pub const SourceEpisodeResolutionState = enum {
    explicit_exact,
    derived_session_turn,
    mismatch,
    unavailable,
};

pub const SourceEpisodeResolution = struct {
    state: SourceEpisodeResolutionState,
    source_episode_id: ?[]u8 = null,

    pub fn deinit(self: *SourceEpisodeResolution, allocator: std.mem.Allocator) void {
        if (self.source_episode_id) |value| allocator.free(value);
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
    if (packet_id) |id| {
        const expected = try packetIdForValueExcludingPacketId(allocator, value);
        defer allocator.free(expected);
        if (!std.mem.eql(u8, id, expected)) try appendCode(allocator, &errors, "packet_id:mismatch");
    }

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

pub fn sourceEpisodeIdAlloc(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    turn_id: []const u8,
) ![]u8 {
    if (session_id.len == 0 or turn_id.len == 0) return error.SourceEpisodeIdentityMissing;
    return std.fmt.allocPrint(allocator, "session:{s}#turn:{s}", .{ session_id, turn_id });
}

/// Resolves the source-episode projection without mutating the DCP value.
/// Callers must validate the original packet (including its packet_id) before
/// consuming this projection so released DCP-v2 bytes remain byte-faithful. A
/// nonempty explicit identity is authoritative; display locators are used only
/// as a compatibility fallback when that carrier is absent.
pub fn resolveSourceEpisodeIdentity(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !SourceEpisodeResolution {
    const packet = bodyObject(value) orelse return .{ .state = .unavailable };
    const source = objectField(packet, "source") orelse return .{ .state = .unavailable };
    const turns = objectField(packet, "turns");

    const explicit_value = source.get("source_episode_id");
    const explicit = if (explicit_value) |candidate| switch (candidate) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    } else null;
    const explicit_malformed = explicit_value != null and explicit == null;

    if (explicit_malformed) {
        return .{ .state = .mismatch };
    }
    if (explicit) |explicit_id| {
        return .{
            .state = .explicit_exact,
            .source_episode_id = try allocator.dupe(u8, explicit_id),
        };
    }

    var derived: ?[]u8 = null;
    if (turns) |turns_obj| {
        if (stringField(source, "session_id")) |session_id| {
            if (stringField(turns_obj, "decision_turn_id")) |turn_id| {
                if (session_id.len > 0 and turn_id.len > 0) {
                    derived = try sourceEpisodeIdAlloc(allocator, session_id, turn_id);
                }
            }
        }
    }
    if (derived) |derived_id| {
        return .{
            .state = .derived_session_turn,
            .source_episode_id = derived_id,
        };
    }
    return .{ .state = .unavailable };
}

pub fn packetIdForCanonicalBody(allocator: std.mem.Allocator, body_without_packet_id: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body_without_packet_id, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "DCP-{s}", .{hex});
}

pub fn packetIdForTextExcludingPacketId(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    return packetIdForValueExcludingPacketId(allocator, parsed.value);
}

pub fn packetIdForValueExcludingPacketId(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const canonical = try canonicalJsonAlloc(allocator, value, true);
    defer allocator.free(canonical);
    return packetIdForCanonicalBody(allocator, canonical);
}

pub fn canonicalJsonText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    return canonicalJsonAlloc(allocator, parsed.value, false);
}

pub fn canonicalJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value, omit_packet_id: bool) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeCanonicalJson(allocator, &out.writer, value, omit_packet_id);
    return out.toOwnedSlice();
}

// DCP-v2 packet identity is a released wire contract. Keep this writer private
// and byte-for-byte equivalent to the original DCP-v2 implementation rather
// than inheriting later canonical JSON profiles.
fn writeCanonicalJson(allocator: std.mem.Allocator, writer: anytype, value: std.json.Value, omit_packet_id: bool) !void {
    switch (value) {
        .object => |obj| {
            var keys = try allocator.alloc([]const u8, obj.count());
            defer allocator.free(keys);
            var key_count: usize = 0;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (omit_packet_id and std.mem.eql(u8, key, "packet_id")) continue;
                keys[key_count] = key;
                key_count += 1;
            }
            std.mem.sort([]const u8, keys[0..key_count], {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);
            try writer.writeByte('{');
            for (keys[0..key_count], 0..) |key, idx| {
                if (idx > 0) try writer.writeByte(',');
                try std.json.Stringify.value(std.json.Value{ .string = key }, .{}, writer);
                try writer.writeByte(':');
                try writeCanonicalJson(allocator, writer, obj.get(key).?, omit_packet_id);
            }
            try writer.writeByte('}');
        },
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, idx| {
                if (idx > 0) try writer.writeByte(',');
                try writeCanonicalJson(allocator, writer, item, omit_packet_id);
            }
            try writer.writeByte(']');
        },
        else => try std.json.Stringify.value(value, .{}, writer),
    }
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
        \\"packet_version":"DCP-v2","packet_id":"DCP-test",
        \\"source":{"session_id":"s","decision_id":"d","source_episode_id":"session:s#turn:t2"},
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

test "DCP validation rejects stale packet id after content edit" {
    const text =
        \\{"decision_context_packet":{
        \\"packet_version":"DCP-v2","packet_id":"DCP-stale",
        \\"source":{"session_id":"s","decision_id":"d","source_episode_id":"session:s#turn:t1"},
        \\"artifact_state":{"reconstructability":"transcript_only"},
        \\"episode":{"question":"q","selected_route":"r","rejected_routes":[],"explicit_rationale":[],"explicit_assumptions":[],"evidence_refs":[],"tools_and_artifacts":[],"skills_and_instructions":[],"outcome_refs":[]},
        \\"turns":{"total_turns":1,"decision_turn_index":1,"decision_turn_id":"t1","source_turn_digest":"sha256:x"},
        \\"anchors":{"pre_decision":{"available":false,"keep_through_turn_index":null,"drop_last_n_turns":null,"anchor_digest":null},"post_decision_pre_outcome":{"available":true,"keep_through_turn_index":1,"drop_last_n_turns":0,"anchor_digest":"sha256:b"},"outcome_aware":{"available":true,"keep_through_turn_index":1,"drop_last_n_turns":0,"anchor_digest":"sha256:c"}},
        \\"contamination":{"injected_skill_blocks":false,"generated_reports":false,"current_audit_prompt":false,"quoted_material":false},
        \\"limitations":[]}}
    ;
    var report = try validateText(std.testing.allocator, text);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.valid);
    try std.testing.expect(containsCode(report.errors, "packet_id:mismatch"));
}

test "DCP source episode identity is canonical across session and turn" {
    const source_episode_id = try sourceEpisodeIdAlloc(std.testing.allocator, "session-one", "turn-two");
    defer std.testing.allocator.free(source_episode_id);
    try std.testing.expectEqualStrings("session:session-one#turn:turn-two", source_episode_id);
}

test "DCP source episode projection distinguishes explicit derived mismatch and unavailable" {
    const Case = struct {
        text: []const u8,
        state: SourceEpisodeResolutionState,
        source_episode_id: ?[]const u8,
    };
    const cases = [_]Case{
        .{
            .text = "{\"decision_context_packet\":{\"source\":{\"session_id\":\"one\",\"source_episode_id\":\"session:one#turn:two\"},\"turns\":{\"decision_turn_id\":\"two\"}}}",
            .state = .explicit_exact,
            .source_episode_id = "session:one#turn:two",
        },
        .{
            .text = "{\"source\":{\"session_id\":\"one\"},\"turns\":{\"decision_turn_id\":\"two\"}}",
            .state = .derived_session_turn,
            .source_episode_id = "session:one#turn:two",
        },
        .{
            .text = "{\"decision_context_packet\":{\"source\":{\"session_id\":\"one\",\"source_episode_id\":\"session:other#turn:two\"},\"turns\":{\"decision_turn_id\":\"two\"}}}",
            .state = .explicit_exact,
            .source_episode_id = "session:other#turn:two",
        },
        .{
            .text = "{\"decision_context_packet\":{\"source\":{\"session_id\":\"one\",\"source_episode_id\":\"\"},\"turns\":{\"decision_turn_id\":\"two\"}}}",
            .state = .mismatch,
            .source_episode_id = null,
        },
        .{
            .text = "{\"source\":{\"rollout_path\":\"/tmp/source.jsonl\"},\"turns\":{}}",
            .state = .unavailable,
            .source_episode_id = null,
        },
    };

    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.text, .{});
        defer parsed.deinit();
        var resolution = try resolveSourceEpisodeIdentity(std.testing.allocator, parsed.value);
        defer resolution.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.state, resolution.state);
        if (case.source_episode_id) |expected| {
            try std.testing.expectEqualStrings(expected, resolution.source_episode_id.?);
        } else {
            try std.testing.expect(resolution.source_episode_id == null);
        }
    }
}

test "released DCP-v2 bytes validate before deriving source episode identity" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const raw = std.Io.Dir.cwd().readFileAlloc(
        io,
        "apps/seq/testdata/decision-capsule/valid-v2-released-no-source-episode-id.json",
        std.testing.allocator,
        .limited(1024 * 1024),
    ) catch try std.Io.Dir.cwd().readFileAlloc(
        io,
        "testdata/decision-capsule/valid-v2-released-no-source-episode-id.json",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(raw);

    var report = try validateText(std.testing.allocator, raw);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.valid);
    try std.testing.expectEqualStrings(
        "DCP-f5a178fe5f03f749ec12664af6bd33f8f10cb9e1f5c45fc4978945612d5bd06a",
        report.packet_id.?,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    var resolution = try resolveSourceEpisodeIdentity(std.testing.allocator, parsed.value);
    defer resolution.deinit(std.testing.allocator);
    try std.testing.expectEqual(SourceEpisodeResolutionState.derived_session_turn, resolution.state);
    try std.testing.expectEqualStrings("session:dcp-basic#turn:turn-decision", resolution.source_episode_id.?);
}

test "DCP-v2 legacy writer locks float and string escape compatibility" {
    const text =
        \\{"packet_id":"root","float":1e23,"fraction":333333333.33333325,"negative_zero":-0.0,"escape":"\b\t\n\f\r\u0000\"\\/","nested":{"packet_id":"nested","value":1e-7}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();

    const canonical = try canonicalJsonAlloc(std.testing.allocator, parsed.value, false);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(
        \\{"escape":"\b\t\n\f\r\u0000\"\\/","float":100000000000000000000000,"fraction":333333333.33333325,"negative_zero":-0,"nested":{"packet_id":"nested","value":0.0000001},"packet_id":"root"}
    , canonical);

    const identity_body = try canonicalJsonAlloc(std.testing.allocator, parsed.value, true);
    defer std.testing.allocator.free(identity_body);
    try std.testing.expectEqualStrings(
        \\{"escape":"\b\t\n\f\r\u0000\"\\/","float":100000000000000000000000,"fraction":333333333.33333325,"negative_zero":-0,"nested":{"value":0.0000001}}
    , identity_body);
}

fn containsCode(codes: []const []u8, needle: []const u8) bool {
    for (codes) |code| {
        if (std.mem.eql(u8, code, needle)) return true;
    }
    return false;
}
